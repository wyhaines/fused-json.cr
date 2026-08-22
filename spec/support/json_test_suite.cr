module JSONTestSuiteSupport
  extend self

  ROOT = File.join(__DIR__, "..", "fixtures", "json_test_suite", "test_parsing")

  # JSONTestSuite intentionally leaves i_ fixtures implementation-defined.
  # These lists encode FusedJSON's strict UTF-8, finite Float64, Int64, BOM,
  # surrogate, and nesting policies.
  I_ACCEPT = %w(
    i_structure_500_nested_arrays.json
  )

  I_REJECT = %w(
    i_number_double_huge_neg_exp.json
    i_number_huge_exp.json
    i_number_neg_int_huge_exp.json
    i_number_pos_double_huge_exp.json
    i_number_real_neg_overflow.json
    i_number_real_pos_overflow.json
    i_number_real_underflow.json
    i_number_too_big_neg_int.json
    i_number_too_big_pos_int.json
    i_number_very_big_negative_int.json
    i_object_key_lone_2nd_surrogate.json
    i_string_1st_surrogate_but_2nd_missing.json
    i_string_1st_valid_surrogate_2nd_invalid.json
    i_string_UTF-16LE_with_BOM.json
    i_string_UTF-8_invalid_sequence.json
    i_string_UTF8_surrogate_U+D800.json
    i_string_incomplete_surrogate_and_escape_valid.json
    i_string_incomplete_surrogate_pair.json
    i_string_incomplete_surrogates_escape_valid.json
    i_string_invalid_lonely_surrogate.json
    i_string_invalid_surrogate.json
    i_string_invalid_utf-8.json
    i_string_inverted_surrogates_U+1D11E.json
    i_string_iso_latin_1.json
    i_string_lone_second_surrogate.json
    i_string_lone_utf8_continuation_byte.json
    i_string_not_in_unicode_range.json
    i_string_overlong_sequence_2_bytes.json
    i_string_overlong_sequence_6_bytes.json
    i_string_overlong_sequence_6_bytes_null.json
    i_string_truncated-utf-8.json
    i_string_utf16BE_no_BOM.json
    i_string_utf16LE_no_BOM.json
    i_structure_UTF-8_BOM_empty_object.json
  )

  def names(prefix : String) : Array(String)
    Dir[File.join(ROOT, "#{prefix}_*.json")]
      .map { |path| File.basename(path) }
      .sort
  end

  def source(name : String) : String
    File.read(File.join(ROOT, name))
  end
end
