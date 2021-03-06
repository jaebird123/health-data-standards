module HQMF2
  # Class representing an HQMF document
  class Document

    include HQMF2::Utilities
    NAMESPACES = {'cda' => 'urn:hl7-org:v3', 'xsi' => 'http://www.w3.org/2001/XMLSchema-instance', 'qdm'=>'urn:hhs-qdm:hqmf-r2-extensions:v1'}

    attr_reader :measure_period, :id, :hqmf_set_id, :hqmf_version_number, :populations, :attributes, :source_data_criteria

    # Create a new HQMF2::Document instance by parsing the given HQMF contents
    # @param [String] containing the HQMF contents to be parsed
    def initialize(hqmf_contents)
      @idgenerator = IdGenerator.new
      @doc = @entry = Document.parse(hqmf_contents)

      remove_population_preconditions(@doc)

      @id = attr_val('cda:QualityMeasureDocument/cda:id/@extension') || attr_val('cda:QualityMeasureDocument/cda:id/@root').upcase
      @hqmf_set_id = attr_val('cda:QualityMeasureDocument/cda:setId/@extension') || attr_val('cda:QualityMeasureDocument/cda:setId/@root').upcase
      @hqmf_version_number = attr_val('cda:QualityMeasureDocument/cda:versionNumber/@value').to_i

      # overidden with correct year information later, but should be produce proper period
      # measure_period_def = @doc.at_xpath('cda:QualityMeasureDocument/cda:controlVariable/cda:measurePeriod/cda:value', NAMESPACES)
      # if measure_period_def
      #   @measure_period = EffectiveTime.new(measure_period_def).to_model
      # end

      #TODO -- figure out if this is the correct thing to do -- probably not, but is
      # necessary to get the bonnie comparison to work.  Currently
      # defaulting measure period to a period of 1 year from 2012 to 2013 this is overriden during
      # calculation with correct year information .  Need to investigate parsing mp from meaures.
      mp_low = HQMF::Value.new('TS',nil, '201201010000',nil, nil, nil)
      mp_high = HQMF::Value.new('TS',nil,'201212312359',nil, nil, nil)
      mp_width = HQMF::Value.new('PQ','a','1',nil, nil, nil)
      @measure_period = HQMF::EffectiveTime.new(mp_low,mp_high,mp_width)

      # Extract measure attributes
      # TODO: Review
      @attributes = @doc.xpath('/cda:QualityMeasureDocument/cda:subjectOf/cda:measureAttribute', NAMESPACES).collect do |attribute|
        read_attribute(attribute)
      end

      # Extract the data criteria
      @data_criteria = []
      @source_data_criteria = []
      @data_criteria_references = {}
      @occurrences_map = {}
      extracted_criteria = []

      @doc.xpath('cda:QualityMeasureDocument/cda:component/cda:dataCriteriaSection/cda:entry', NAMESPACES).each do |entry|
        extracted_criteria << entry
      end

      # Used to keep track of referenced data criteria ids
      @reference_ids = []

      # Extract the source data criteria from data criteria
      @source_data_criteria, collapsed_source_data_criteria = SourceDataCriteriaHelper.get_source_data_criteria_list(extracted_criteria, @data_criteria_references, @occurrences_map)
      extracted_criteria.each do |entry|
        criteria = DataCriteria.new(entry, @data_criteria_references, @occurrences_map)

        # Sometimes there are multiple criteria with the same ID, even though they're different; in the HQMF
        # criteria refer to parent criteria via outboundRelationship, using an extension (aka ID) and a root;
        # we use just the extension to follow the reference, and build the lookup hash using that; since they
        # can repeat, we wind up overwriting some content. This becomes important when we want, for example,
        # the code_list_id and we overwrite the parent with the code_list_id with a child with the same ID
        # without the code_list_id. As a temporary approach, we only overwrite a data criteria reference if
        # it doesn't have a code_list_id. As a longer term approach we may want to use the root for lookups.
        if criteria && (@data_criteria_references[criteria.id].nil? || @data_criteria_references[criteria.id].code_list_id.nil?)
          @data_criteria_references[criteria.id] = criteria
        end
        if collapsed_source_data_criteria.has_key?(criteria.id)
          criteria.instance_variable_set(:@source_data_criteria, collapsed_source_data_criteria[criteria.id])
        end
        handle_variable(criteria) if criteria.variable

        @reference_ids.concat(criteria.children_criteria)
        if criteria.temporal_references
          criteria.temporal_references.each do |tr|
            @reference_ids << tr.reference.id if tr.reference.id != HQMF::Document::MEASURE_PERIOD_ID
          end
        end
        @data_criteria << criteria
      end

      # Patch descriptions for all data criteria and source data criteria

      # @data_criteria.each { |dc| dc.patch_descriptions(@data_criteria_references) }
      # @source_data_criteria.each { |sdc| sdc.patch_descriptions(@data_criteria_references) }


      # Detect missing specific occurrences and clone source data criteria
      #detect_missing_specifics

      # Extract the population criteria and population collections
      @populations = []
      @population_criteria = []
      @stratifications = []

      population_counters = {}
      ids_by_hqmf_id = {}
      has_observation = false
       #look for observation data in separate section but create a population for it if it exists
      observation_section = @doc.xpath('/cda:QualityMeasureDocument/cda:component/cda:measureObservationSection', NAMESPACES)
      if !observation_section.empty?
        observation_section.xpath("cda:definition",NAMESPACES).each do |criteria_def|
          criteria_id = "OBSERV"
          criteria = PopulationCriteria.new(criteria_def, self, @idgenerator)
          criteria.type="OBSERV"
          # this section constructs a human readable id.  The first IPP will be IPP, the second will be IPP_1, etc.  This allows the populations to be
          # more readable.  The alternative would be to have the hqmf ids in the populations, which would work, but is difficult to read the populations.
          if ids_by_hqmf_id["#{criteria.hqmf_id}"]
            criteria.create_human_readable_id(ids_by_hqmf_id[criteria.hqmf_id])
          else
            if population_counters[criteria_id]
              population_counters[criteria_id] += 1
              criteria.create_human_readable_id("#{criteria_id}_#{population_counters[criteria_id]}")
            else
              population_counters[criteria_id] = 0
              criteria.create_human_readable_id(criteria_id)
            end
            ids_by_hqmf_id["#{criteria.hqmf_id}"] = criteria.id
          end

          @population_criteria << criteria
          has_observation = true
        end
      end
      document_populations = @doc.xpath('cda:QualityMeasureDocument/cda:component/cda:populationCriteriaSection', NAMESPACES)
      # Sort the populations based on the id/extension, since the populations may be out of order; there doesn't seem to
      # be any other way that order is indicated in the HQMF
      document_populations = document_populations.sort_by { |pop| pop.at_xpath('cda:id/@extension', NAMESPACES).try(:value) }
      number_of_populations = document_populations.length
      document_populations.each_with_index do |population_def, population_index|
        population = {}

        {
          HQMF::PopulationCriteria::IPP => 'initialPopulationCriteria',
          HQMF::PopulationCriteria::DENOM => 'denominatorCriteria',
          HQMF::PopulationCriteria::NUMER => 'numeratorCriteria',
          HQMF::PopulationCriteria::DENEXCEP => 'denominatorExceptionCriteria',
          HQMF::PopulationCriteria::DENEX => 'denominatorExclusionCriteria',
          HQMF::PopulationCriteria::MSRPOPL => 'measurePopulationCriteria',
          HQMF::PopulationCriteria::MSRPOPLEX => 'measurePopulationExclusionCriteria'
        }.each_pair do |criteria_id, criteria_element_name|
          criteria_def = population_def.at_xpath("cda:component[cda:#{criteria_element_name}]", NAMESPACES)
          if criteria_def
            build_population_criteria(criteria_def, criteria_id, criteria_element_name, ids_by_hqmf_id, population, population_counters)
          end
        end


        id_def = population_def.at_xpath('cda:id/@extension', NAMESPACES)
        population['id'] = id_def ? id_def.value : "Population#{population_index}"
        title_def = population_def.at_xpath('cda:title/@value', NAMESPACES)
        population['title'] = title_def ? title_def.value : "Population #{population_index}"

        if has_observation
          population['OBSERV'] = 'OBSERV'
        end
        @populations << population

        # handle stratifications (EP137, EP155)
        population_def.xpath("cda:component/cda:stratifierCriteria[not(cda:component/cda:measureAttribute/cda:code[@code  = 'SDE'])]/..", NAMESPACES).each_with_index do |criteria_def, criteria_def_index|
          index =  number_of_populations + ((population_index - 1) * criteria_def.xpath('./*/cda:precondition').length) + criteria_def_index
          criteria_id = HQMF::PopulationCriteria::STRAT
          stratified_population = population.dup
          stratified_population['stratification'] = criteria_def.at_xpath("./*/cda:id/@root").try(:value) || "#{criteria_id}-#{criteria_def_index}"

          # Skip this Stratification if any precondition doesn't contain any preconditions
          next unless PopulationCriteria.new(criteria_def, self, @idgenerator).preconditions.all?{|prcn| prcn.preconditions.length>0}
          build_population_criteria(criteria_def, criteria_id, 'stratifierCriteria', ids_by_hqmf_id, stratified_population, population_counters)

          stratified_population['id'] = id_def ? "#{id_def.value} - Stratification #{criteria_def_index+1}": "Population#{index}"
          title_def = population_def.at_xpath('cda:title/@value', NAMESPACES)
          stratified_population['title'] = title_def ? "#{title_def.value} - Stratification #{criteria_def_index+1}" : "Population #{index}"
          @stratifications << stratified_population
        end
      end

      # Push in the stratification populations after the unstratified populations
      @populations.push *@stratifications

      @reference_ids.uniq

      # Remove any data criteria from the main data criteria list that already has an equivalent member and no references to it
      # The goal of this is to remove any data criteria that should not be purely a source
      # Ignore any referenced by child criteria
      base_criteria_defs = ['patient_characteristic_ethnicity', 'patient_characteristic_gender', 'patient_characteristic_payer', 'patient_characteristic_race']
      @data_criteria.reject! do |dc|
        to_reject = true
        to_reject &&= @reference_ids.index(dc.id).nil? # don't reject if anything refers directly to this criteria
        to_reject &&= !base_criteria_defs.include?(dc.definition) # don't reject if it is a "base" criteria (no references but must exist)
        to_reject &&= !@data_criteria.detect do |dc2|
                        similar_criteria = true
                        similar_criteria &&= dc != dc2 # Don't check against itself
                        similar_criteria &&= dc.code_list_id == dc2.code_list_id # Ensure code list ids are the same
                        similar_criteria &&= detect_criteria_covered_by_another(dc, dc2)
                      end.nil? # don't reject unless there is a similar element
      end
    end

    # Get the title of the measure
    # @return [String] the title
    def title
      @doc.at_xpath('cda:QualityMeasureDocument/cda:title/@value', NAMESPACES).inner_text
    end

    # Get the description of the measure
    # @return [String] the description
    def description
      description = @doc.at_xpath('cda:QualityMeasureDocument/cda:text/@value', NAMESPACES)
      description==nil ? '' : description.inner_text
    end

    # Get all the population criteria defined by the measure
    # @return [Array] an array of HQMF2::PopulationCriteria
    def all_population_criteria
      @population_criteria
    end

    # Get a specific population criteria by id.
    # @param [String] id the population identifier
    # @return [HQMF2::PopulationCriteria] the matching criteria, raises an Exception if not found
    def population_criteria(id)
      find(@population_criteria, :id, id)
    end

    # Get all the data criteria defined by the measure
    # @return [Array] an array of HQMF2::DataCriteria describing the data elements used by the measure
    def all_data_criteria
      @data_criteria
    end

    # Get a specific data criteria by id.
    # @param [String] id the data criteria identifier
    # @return [HQMF2::DataCriteria] the matching data criteria, raises an Exception if not found
    def data_criteria(id)
      find(@data_criteria, :id, id)
    end

    #needed so data criteria can be added to a document from other objects
    def add_data_criteria(dc)
      @data_criteria << dc
    end

    def find_criteria_by_lvn(lvn)
      find(@data_criteria, :local_variable_name, lvn)
    end

    # Parse an XML document from the supplied contents
    # @return [Nokogiri::XML::Document]
    def self.parse(hqmf_contents)
      doc = hqmf_contents.kind_of?(Nokogiri::XML::Document) ? hqmf_contents : Nokogiri::XML(hqmf_contents)
      doc.root.add_namespace_definition('cda', 'urn:hl7-org:v3')
      doc
    end

    def to_model

      dcs = all_data_criteria.collect {|dc| dc.to_model}
      pcs = all_population_criteria.collect {|pc| pc.to_model}
      sdc = source_data_criteria.collect{|dc| dc.to_model}
      dcs = update_data_criteria(dcs, sdc)
      HQMF::Document.new(id, id, hqmf_set_id, hqmf_version_number, @cms_id, title, description, pcs, dcs, sdc, attributes, measure_period, populations)
    end

    # Create grouper data criteria for encapsulating variable data criteria
    # and update document data criteria list and references map
    def handle_variable(data_criteria)
      grouper_data_criteria = data_criteria.extract_variable_grouper
      return unless grouper_data_criteria
      @data_criteria_references[data_criteria.id] = data_criteria
      @data_criteria_references[grouper_data_criteria.id] = grouper_data_criteria
      @data_criteria << grouper_data_criteria
      @source_data_criteria << SourceDataCriteriaHelper.strip_non_sc_elements(grouper_data_criteria)
    end

    # Update the data criteria to handle variables properly
    def update_data_criteria(data_criteria, source_data_criteria)
      # step through each criteria and look for groupers (type derived) with one child
      data_criteria.map do |criteria|
        puts "Missing children criteria: #{criteria.id}" if criteria.type == :derived && criteria.children_criteria.nil?
        if criteria.type == :derived && criteria.children_criteria.try(:length) == 1
          source_data_criteria.each do |source_criteria|
            if source_criteria.title == criteria.children_criteria[0]
              criteria.children_criteria = source_criteria.children_criteria
              #if criteria.is_same_type?(source_criteria)
              criteria.update_copy( source_criteria.hard_status, source_criteria.title, source_criteria.description,
                                    source_criteria.derivation_operator, source_criteria.definition )#, occur_letter )
            end
          end
        end
        criteria
      end
    end

    # If a precondition references a population, remove it
    def remove_population_preconditions(doc)
      #population sections
      pop_ids = doc.xpath("//cda:populationCriteriaSection/cda:component[@typeCode='COMP']/*/cda:id",NAMESPACES)
      #find the population entries and get their ids
      pop_ids.each do |p_id|
        doc.xpath("//cda:precondition[./cda:criteriaReference/cda:id[@extension='#{p_id["extension"]}' and @root='#{p_id["root"]}']]",NAMESPACES).remove
      end
    end

    def build_population_criteria(criteria_def, criteria_id, criteria_element_name, ids_by_hqmf_id, population, population_counters)
      criteria = PopulationCriteria.new(criteria_def, self, @idgenerator)
      # ignore empty STRAT populations
      return if criteria_element_name == 'stratifierCriteria' && criteria.preconditions.blank?

      # check to see if we have an identical population criteria.
      # this can happen since the hqmf 2.0 will export a DENOM, NUMER, etc for each population, even if identical.
      # if we have identical, just re-use it rather than creating DENOM_1, NUMER_1, etc.
      identical = @population_criteria.select {|pc| pc.to_model.hqmf_id == criteria.to_model.hqmf_id}

      @reference_ids.concat(criteria.to_model.referenced_data_criteria)

      if (identical.empty?)
        # this section constructs a human readable id.  The first IPP will be IPP, the second will be IPP_1, etc.  This allows the populations to be
        # more readable.  The alternative would be to have the hqmf ids in the populations, which would work, but is difficult to read the populations.
        if ids_by_hqmf_id["#{criteria.hqmf_id}-#{population['stratification']}"]
          criteria.create_human_readable_id(ids_by_hqmf_id["#{criteria.hqmf_id}-#{population['stratification']}"])
        else
          if population_counters[criteria_id]
            population_counters[criteria_id] += 1
            criteria.create_human_readable_id("#{criteria_id}_#{population_counters[criteria_id]}")
          else
            population_counters[criteria_id] = 0
            criteria.create_human_readable_id(criteria_id)
          end
          ids_by_hqmf_id["#{criteria.hqmf_id}-#{population['stratification']}"] = criteria.id
        end


        @population_criteria << criteria
        population[criteria_id] = criteria.id
      else
        population[criteria_id] = identical.first.id
      end
    end

    private

    def find(collection, attribute, value)
      collection.find {|e| e.send(attribute)==value}
    end

    # Check if one data criteria contains the others information by checking that one has everything the other has (or more)
    def detect_criteria_covered_by_another(data_criteria, check_criteria)
      base_checks = true

      # Check whhether basic features are the same
      base_checks &&= data_criteria.definition == check_criteria.definition # same definition
      base_checks &&= data_criteria.status == check_criteria.status # same status
      base_checks &&= data_criteria.children_criteria.sort.join(",") == check_criteria.children_criteria.sort.join(",") # same children
      # Ensure it doesn't contain basic elements that should not be removed
      base_checks &&= !data_criteria.variable # Ensure it's not a variable
      base_checks &&= data_criteria.derivation_operator.nil? # Ensure it doesn't it have a derivation operator
      base_checks &&= data_criteria.subset_operators.empty? # Ensure it doesn' it have a subset operator

      same_value = data_criteria.value.nil? || data_criteria.value.try(:to_model).try(:to_json) == check_criteria.value.try(:to_model).try(:to_json)
      same_temporal_references = data_criteria.temporal_references.nil? || data_criteria.temporal_references.empty?
      same_field_values = data_criteria.field_values.nil? || data_criteria.field_values.empty? || data_criteria.field_values.try(:to_json) == check_criteria.field_values.try(:to_json)
      same_negation_values = data_criteria.negation_code_list_id.nil? || data_criteria.negation_code_list_id == check_criteria.negation_code_list_id

      base_checks && same_value && same_temporal_references && same_field_values && same_negation_values
    end

    def detect_unstratified
      missing_populations = []
      # populations are keyed off of values rather than the codes
      existing_populations = @populations.map{|p| p.except("id","title").values.join('-')}.uniq
      @populations.each do |population|
        keys = population.keys - ['STRAT','stratification', 'id', 'title']
        missing_populations |= [population.values_at(*keys).compact.join('-')]
      end

      missing_populations -= existing_populations

      # reverse the order and prepend them to @populations
      missing_populations.reverse.each do |population|
        p = {}
        population.split('-').each do |code|
          p[code.split('_').first] = code
        end
        @populations.unshift p
      end

      # fix population ids and titles
      @populations.each_with_index do |population, population_index|
        population['id'] ||= "Population#{population_index+1}"
        population['title'] ||= "Population #{population_index+1}"
        population['id'].gsub!(/\d+\z/, "#{population_index+1}")
        population['title'].gsub!(/\d+\z/, "#{population_index+1}")
      end

    end

    # If we have a specific occurrence that references a source data criteria
    # that doesn't have an occurrence on it, just clone the sdc and add it
    def detect_missing_specifics
      source_data_criteria_references = {}
      @source_data_criteria.each { |sdc| source_data_criteria_references[sdc.id] = sdc }
      specifics_map = {}
      @data_criteria.each do |dc|
        # skip data criteria that aren't specific and skip variables
        next unless dc.specific_occurrence && !dc.variable && !dc.id.start_with?("GROUP_")
        sdc = source_data_criteria_references[dc.source_data_criteria]
        next if sdc.try(:specific_occurrence) == dc.specific_occurrence
        specifics_map[dc.source_data_criteria] ||= []
        specifics_map[dc.source_data_criteria] << dc.specific_occurrence
        cloned_sdc = "Occurrence#{dc.specific_occurrence}_#{dc.source_data_criteria}"
        # puts "Updated #{dc.id} SDC from #{dc.source_data_criteria} to #{cloned_sdc}"
        dc.patch_sdc_clone(nil, cloned_sdc, nil, dc.source_data_criteria.upcase)
      end
      specifics_map.each do |sdc_id, occurrences|
        existing = @data_criteria_references[sdc_id]
        occurrences.uniq.each do |occr|
          sdc_clone = existing.extract_source_data_criteria
          sdc_clone.patch_sdc_clone("Occurrence#{occr}_#{sdc_clone.id}", nil, occr, nil)
          # puts "Created SDC clone #{sdc_clone.id} with OCCR #{sdc_clone.specific_occurrence}"
          @source_data_criteria << sdc_clone
        end
      end
    end

    def extract_preconditions(precondition, list)
      precondition.preconditions.each do |prcn|
        extract_preconditions(prcn, list)
        list << prcn if prcn.reference
      end
    end

    def read_attribute(attribute)
      id = attribute.at_xpath('./cda:id/@root', NAMESPACES).try(:value)
      code = attribute.at_xpath('./cda:code/@code', NAMESPACES).try(:value)
      name = attribute.at_xpath('./cda:code/cda:displayName/@value', NAMESPACES).try(:value)
      value = attribute.at_xpath('./cda:value/@value', NAMESPACES).try(:value)

      id_obj = nil
      if attribute.at_xpath('./cda:id', NAMESPACES)
        id_obj = HQMF::Identifier.new(attribute.at_xpath('./cda:id/@xsi:type', NAMESPACES).try(:value), id, attribute.at_xpath('./cda:id/@extension', NAMESPACES).try(:value))
      end

      code_obj = nil;
      if attribute.at_xpath('./cda:code', NAMESPACES)
        nullFlavor = attribute.at_xpath('./cda:code/@nullFlavor', NAMESPACES).try(:value)
        oText = attribute.at_xpath('./cda:code/cda:originalText', NAMESPACES) ? attribute.at_xpath('./cda:code/cda:originalText/@value', NAMESPACES).try(:value) : nil
        code_obj = HQMF::Coded.new(attribute.at_xpath('./cda:code/@xsi:type', NAMESPACES).try(:value) || 'CD',
                                   attribute.at_xpath('./cda:code/@codeSystem', NAMESPACES).try(:value),
                                   code,
                                   attribute.at_xpath('./cda:code/@valueSet', NAMESPACES).try(:value),
                                   name,
                                   nullFlavor,
                                   oText)


        # Mapping for nil values to align with 1.0 parsing
        if code == nil
          code = nullFlavor
        end

        if name == nil
          name = oText
        end

      end

      value_obj = nil
      if attribute.at_xpath('./cda:value', NAMESPACES)
        type = attribute.at_xpath('./cda:value/@xsi:type', NAMESPACES).try(:value)
        case type
        when 'II'
          value_obj = HQMF::Identifier.new(type,
                                           attribute.at_xpath('./cda:value/@root', NAMESPACES).try(:value),
                                           attribute.at_xpath('./cda:value/@extension', NAMESPACES).try(:value))
          if value == nil
            value = attribute.at_xpath('./cda:value/@extension', NAMESPACES).try(:value)
          end
        when 'ED'
          value_obj = HQMF::ED.new(type, value, attribute.at_xpath('./cda:value/@mediaType', NAMESPACES).try(:value))
        when 'CD'
          value_obj = HQMF::Coded.new('CD', attribute.at_xpath('./cda:value/@codeSystem', NAMESPACES).try(:value),
                                      attribute.at_xpath('./cda:value/@code', NAMESPACES).try(:value),
                                      attribute.at_xpath('./cda:value/@valueSet', NAMESPACES).try(:value),
                                      attribute.at_xpath('./cda:value/cda:displayName/@value', NAMESPACES).try(:value))
        else
          value_obj = value.present? ? HQMF::GenericValueContainer.new(type, value) : HQMF::AnyValue.new(type)
        end
      end

      # Handle the cms_id
      if name.include? "eMeasure Identifier"
        @cms_id = "CMS#{value}v#{@hqmf_version_number}"
      end

      HQMF::Attribute.new(id, code, value, nil, name, id_obj, code_obj, value_obj)

    end
  end
end
