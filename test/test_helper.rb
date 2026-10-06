ENV["CANVAS_TOKEN"] = "test-token"
ENV["CANVAS_URL"] = "https://temecula.instructure.com"
ENV["PORT"] = "0"

require "minitest/autorun"
require "tmpdir"
require "fileutils"

TEST_TMP_DIR = Dir.mktmpdir("canvas-dashboard-test")
ENV["CACHE_FILE"] = File.join(TEST_TMP_DIR, "canvas_cache.json")
ENV["EVENT_JOURNAL_FILE"] = File.join(TEST_TMP_DIR, "event_journal.json")
ENV["COURSE_NAME_MAPPINGS_FILE"] = File.join(TEST_TMP_DIR, "course_names.json")
ENV["GRADE_OVERRIDES_FILE"] = File.join(TEST_TMP_DIR, "grade_overrides.json")

require_relative "../canvas_dashboard/app"

Minitest.after_run do
  FileUtils.remove_entry(TEST_TMP_DIR) if File.exist?(TEST_TMP_DIR)
end

class Minitest::Test
  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def with_replaced_method(receiver, name, replacement)
    singleton_class = receiver.singleton_class
    had_method = singleton_class.method_defined?(name)
    original = singleton_class.instance_method(name) if had_method

    singleton_class.define_method(name) do |*args, **kwargs, &block|
      replacement.call(*args, **kwargs, &block)
    end

    yield
  ensure
    if had_method
      singleton_class.define_method(name, original)
    else
      singleton_class.remove_method(name)
    end
  end
end