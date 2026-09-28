require_relative "test_helper"

Dir[File.join(__dir__, "*_test.rb")].sort.each do |file|
  require file
end