# Name of Author: Peter Uherek
# Created at: 30.11. 2014
#
# Description: Vytvorenie a naplnenie generickej tabulky na zaklade csv suboru.
require 'cmd_interface'
require 'separator_checker'
class AnalyzeFunction

  def reanalyze(dataset, send_mail)

    changed_columns=dataset.headers.first.columns.where(analyze: true)
    changed_columns.each do |col|
      if (col.analyze == true)
        # puts "looking for gropings with columnid: #{col.id}"
        columnGeos = dataset.groupings.where(columnid: col.id)
        columnGeos.destroy_all

        if(col.type_id == 5)
          AnalyzeFunction.new.delay.count_lat_long(dataset,col)
        end
        if(col.type_id == 4)
          AnalyzeFunction.new.delay.r_analyze_dataset_user(dataset,col)
        end
        col.analyze = false
        col.save
      end
    end

    if send_mail == 'true'
      dataset.user.send_success_email(dataset)
    end

    dataset.status = 'P'

    dataset.save
  end

def r_clean_dataset(dataset)
    path = dataset.storage
    character = SeparatorChecker.new.find_separator(path)
    cmd = "Rscript app/lib/r/cleanData.R #{path} '#{character}'"
    puts cmd
    CMDInterface.new.Exec_command(cmd)
end

def r_analyze_dataset(dataset)
    dataset_id = dataset.id
    header_id = dataset.headers.first.id

    config   = Rails.configuration.database_configuration
    dbName = config[Rails.env]["database"]
    dbUsername = config[Rails.env]["username"]
    dbPassword = config[Rails.env]["password"]

    cmd = "Rscript app/lib/r/analyze.R #{dbName} #{dbUsername} #{dbPassword} #{dataset_id} #{header_id} "
    puts cmd
    CMDInterface.new.Exec_command(cmd)
end

def r_analyze_dataset_user(dataset,column)
  dataset_id = dataset.id
  column_id = column.id
  column_name = column.label


  config   = Rails.configuration.database_configuration
  dbName = config[Rails.env]["database"]
  dbUsername = config[Rails.env]["username"]
  dbPassword = config[Rails.env]["password"]

  cmd = "Rscript app/lib/r/analyze.R  #{dbName} #{dbUsername} #{dbPassword} #{dataset_id} #{column_id} #{column_name}"
  puts cmd
  CMDInterface.new.Exec_command(cmd)
end

 def analyze_dataset
 	@new_class, @column_names = loading_table("1:1")
 	number_of_unique_values_in_da_columnes(@new_class,@column_names)
 	#number_of_unique(@new_class,@column_names)
 end

 private
 def number_of_unique(new_class,column_names)
 	column_names.each do |column_name|
		puts column_name
		result = new_class.find(
		:all,
		:select => 'count(*) count, #{column_name}',
		:group => '#{column_name}',
		:order => 'count DESC',
		:linit => 1)

		#puts result
	end
 end


 private
 def number_of_unique_values_in_da_columnes(new_class,column_names)
 	column_names.each do |column_name|
		result = new_class.select(column_name).distinct.count()
		puts result
	end
 end

 private
 def loading_table(name_of_dataset)
    begin
	new_class = Class.new(ActiveRecord::Base) { self.table_name = name_of_dataset }
	column_names = new_class.columns.map(&:name)
	rescue
		puts "Error #{$!}"
	end
	return new_class,column_names
 end

  public
  def count_lat_long(dataset, column)

    @logger = Logger.new(STDOUT)
    @logger.level = Logger::DEBUG

    @logger.debug "Searching information about location for data from column, #{column.label}, is going to start"

    name_of_dataset_data_table = dataset.data_table_name
    data = Class.new(ActiveRecord::Base) { self.table_name = name_of_dataset_data_table }

    datasetGeos = []                                           # povodna snaha o jediny insert, nakoniec zrejme useless
    maximumSubsequentGoogleGEOSearchFailures = Settings.maximumSubsequentGoogleGEOSearchFailures
    currentlyFailedGoogleGEOSearchesInRow = 0

    for i in 1..data.count do
      geoName = data.find(i)[column.label]
      existingGeocordinate = Coordinate.find_by_mesto(geoName) # toto bude velmi neefektivne :-O, select v cykle ftw
      if existingGeocordinate.nil?
          sleep(0.5)                                           # kvoli prekroceniu limitu za sekundu requestov na google (alex)
          coordinates = Geocoder.coordinates(geoName)
          unless coordinates == nil
            currentlyFailedGoogleGEOSearchesInRow = 0         # reset pocitadla failnutych requestov

            datasetGeos << Coordinate.create(
                :lat => coordinates[0],
                :lng => coordinates[1],
                :mesto => geoName
            )
          else
              @logger.info "Google has not returned coordinates for Geo:  #{geoName}"
              currentlyFailedGoogleGEOSearchesInRow += 1

              if currentlyFailedGoogleGEOSearchesInRow >= maximumSubsequentGoogleGEOSearchFailures
                @logger.warn "Maximum number of failed subsequent Google search responses reached"
                @logger.debug "Probably column, #{column.label}, does not consist information about location"
                return false
              end
          end
      else
          datasetGeos << existingGeocordinate
      end
    end

    # zabezpecuje insert po failnuti unikatnosti :)
    datasetGeos.each do |datasetGeo|

      datasetCoordinateGrouping = Grouping.create(
          :dataset_id => dataset.id,
          :coordinate_id => datasetGeo.id,
          :columnid => column.id
      )

      begin
        datasetCoordinateGrouping.save
      rescue ActiveRecord::RecordInvalid => invalid
        @logger.info invalid.record.errors
        @logger.info "Coordinate #{datasetGeo.id}(#{datasetGeo.mesto}) for dataset #{dataset.id} already exists"
      end
      @logger.debug "Searching information about location for data from column, #{column.label}, end"
      return true
    end

    # datasetGeos.each do |datasetGeo|
    #   dataset.groupings.each do |grouping|
    #     if(grouping.coordinate_id == datasetGeo.id)
    #       grouping.columnid = column.id
    #       grouping.save
    #     end
    #   end
    # end

  end
end