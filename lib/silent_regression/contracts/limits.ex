defmodule SilentRegression.Contracts.Limits do
  @moduledoc false

  @contract_bytes 100_000
  @output_bytes 1_000_000
  @rule_nodes 100
  @rule_depth 5
  @group_children 20
  @rule_id_characters 80
  @json_pointer_characters 1_000
  @json_pointer_tokens 32
  @alternatives 20
  @alternative_bytes 500
  @source_id_characters 128
  @evidence_excerpt_bytes 500

  def contract_bytes, do: @contract_bytes
  def output_bytes, do: @output_bytes
  def rule_nodes, do: @rule_nodes
  def rule_depth, do: @rule_depth
  def group_children, do: @group_children
  def rule_id_characters, do: @rule_id_characters
  def json_pointer_characters, do: @json_pointer_characters
  def json_pointer_tokens, do: @json_pointer_tokens
  def alternatives, do: @alternatives
  def alternative_bytes, do: @alternative_bytes
  def source_id_characters, do: @source_id_characters
  def evidence_excerpt_bytes, do: @evidence_excerpt_bytes
end
