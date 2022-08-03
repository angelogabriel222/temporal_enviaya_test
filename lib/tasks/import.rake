namespace :import do
  desc "TODO"
  task zip_codes: :environment do
    puts '******************************** INIT IMPORT ZIP CODE ********************************'
    puts 'The import can take more than 22 minutes'
    puts 'In case of an upgrade it may take 5 minutes'
    
    init_time = Time.now
    @country = Country.where(code: 'MX').first || Country.create(code: 'MX')

    # errors exceptions vars
    @city_errs = []
    @municipality_errs = []
    @postal_code_errs = []
    @neighborhood_errs = []
    @records_errors = []

    # hash counters
    @hash_counters = {
      states: 0,
      cities: 0,
      municipalities: 0,
      postal_codes: 0,
      neighborhood: 0,
      postal_codes_updated: 0
    }

    @all_data = PostalCode.count.zero? && Neighborhood.count.zero? && Municipality.count.zero? && City.count.zero?
    @codes = []

    xlsx = Roo::Excelx.new('./lib/tasks/files/postal_codes_Mexico.xlsx')
    # Iterating sheets except the first (Nota)
    xlsx.sheets.drop(1).each do |sheet|
      puts "Creating State -------------------------------- #{sheet}"

      state = State.where(name: sheet, country_id: @country.id).first
      unless state
        state = State.create(name: sheet, country_id: @country.id)
        @hash_counters[:states] += 1
      end

      xlsx.sheet(sheet).each_with_index do |row, index|
        next unless !is_header(row)
        @codes << row[0] unless @all_data

        # Block exception when column d_ciudad (row[5]) is empty
        unless !row[5].blank?
          municipality = Municipality.where(name: row[3], country_id: @country.id, state_id: state.id).first
          if municipality
            city = municipality.city
          else
            @records_errors << { postal_code: row[0], municipality: row[3], state: sheet }
            next
          end
        else
          city = City.where(name: row[5], country_id: @country.id).first
          unless city
            puts "Creating City -------------------------------- #{row[5]}"
            city = City.new(name: row[5], country_id: @country.id, state_id: state.id)
  
            unless city.valid? && city.save
              @city_errs << { state: city, error: city.errors.full_messages, postal_code: row[0] } 
              next 
            end
            @hash_counters[:cities] += 1
          end
          municipality = Municipality.where(name: row[3], country_id: @country.id, city_id: city.id).first
        end

        unless municipality
          puts "Creating Municipality -------------------------------- #{row[3]}"
          municipality = Municipality.new(name: row[3], country_id: @country.id, state_id: state.id, city_id: city.id)
          unless municipality.valid? && municipality.save
            @municipality_errs << { state: municipality, error: municipality.errors.full_messages, postal_code: row[0] } 
            next 
          end
          @hash_counters[:municipalities] += 1
        end

        postal_code = PostalCode.where(code: row[0], country_id: @country.id).first
        unless postal_code
          postal_code = create_postal_code(row, state, municipality)
          next unless postal_code
          @hash_counters[:postal_codes] += 1
        else
          unless postal_code.code == row[0] && postal_code.municipality.name == row[3]
            postal_code.delete
            postal_code = create_postal_code(row, state, municipality)
            next unless postal_code
            @hash_counters[:postal_codes_updated] += 1
          end
        end

        neighborhood = Neighborhood.where(name: row[2], country_id: @country.id, postal_code_id: postal_code.id).first
        unless neighborhood
          neighborhood = Neighborhood.new(name: row[2], country_id: @country.id, state_id: state.id, municipality_id: municipality.id, postal_code_id: postal_code.id, city_id: city.id)
          unless neighborhood.valid? && neighborhood.save
            @neighborhood_errs << { state: neighborhood, error: neighborhood.errors.full_messages, postal_code: row[0] } 
            next
          end
          @hash_counters[:neighborhood] += 1
        end

        city_postal = CitiesPostalCode.where(city_id: city.id, postal_code_id: postal_code.id).first
        unless city_postal
          CitiesPostalCode.create(city_id: city.id, postal_code_id: postal_code.id)
        end

      end
    end

    del_excess(@codes) unless @all_data

    finish_time = Time.now
    puts ''
    puts "load started at #{init_time.strftime("%I:%M%p")}"
    puts "load completed at #{finish_time.strftime("%I:%M%p")}"
    puts "Import done in #{((finish_time - init_time) / 1.minutes).round} minutes"

    puts '-----------------------------------------------------------'
    puts "States created ----------------------------------------- #{@hash_counters[:states]}"
    puts "Cities created ----------------------------------------- #{@hash_counters[:cities]}"
    puts "Municipalities created --------------------------------- #{@hash_counters[:municipalities]}"
    puts "Postal codes created ----------------------------------- #{@hash_counters[:postal_codes]}"
    puts "Neighborhoods created ---------------------------------- #{@hash_counters[:neighborhood]}"
    puts "Postal codes updated ---------------------------------- #{@hash_counters[:postal_codes_updated]}"
    puts '-----------------------------------------------------------'

    unless @city_errs.length.zero?
      puts "It has not been possible to create #{@city_errs.length} cities, more details in /city_errs.json"
      File.open('city_errs.json', 'w') { |file| file.write(@city_errs.to_json) }
    end
    
    unless @municipality_errs.length.zero?
      puts "It has not been possible to create #{@municipality_errs.length} municipalities, more details in /municipality_errs.json"
      File.open('municipality_errs.json', 'w') { |file| file.write(@municipality_errs.to_json) }
    end
    
    unless @postal_code_errs.length.zero?
      puts "It has not been possible to create #{@postal_code_errs.length} postal codes, more details in /postal_code_errs.json"
      File.open('postal_code_errs.json', 'w') { |file| file.write(@postal_code_errs.to_json) }
    end
    
    unless @neighborhood_errs.length.zero?
      puts "It has not been possible to create #{@neighborhood_errs.length} neighborhoods, more details in /neighborhood_errs.json"
      File.open('neighborhood_errs.json', 'w') { |file| file.write(@neighborhood_errs.to_json) }
    end

    unless @records_errors.length.zero?
      puts "It has not been possible to create #{@records_errors.length} records because they have no city, more details in /records_errors.json"
      File.open('records_errors.json', 'w') { |file| file.write(@records_errors.to_json) }
    end
  end

  def is_header(row)
    row.find { |r| r == 'd_codigo' } && row.find { |r| r == 'd_asenta' } && row.find { |r| r == 'd_tipo_asenta' } && row.find { |r| r == 'D_mnpio' } && row.find { |r| r == 'd_estado' } && row.find { |r| r == 'd_ciudad' } && row.find { |r| r == 'd_CP' } && row.find { |r| r == 'c_estado' } && row.find { |r| r == 'c_oficina' }
  end

  def del_excess(codes_file)
    codes_bd = PostalCode.pluck(:code)
    excess = codes_bd.select{ |e| !codes_file.include?(e) }

    if excess.length.positive?
      PostalCode.where(code: excess).delete_all
      puts "The #{excess.join(', ')} codes have been removed from the database since they were deleted from Excel"
    end
  end

  def create_postal_code(row, state, municipality)
    postal_code = PostalCode.new(code: row[0], country_id: @country.id, state_id: state.id, municipality_id: municipality.id)
    unless postal_code.valid? && postal_code.save
      @postal_code_errs << { state: postal_code, error: postal_code.errors.full_messages, postal_code: row[0] } 
      false
    else
      postal_code
    end
  end
end
