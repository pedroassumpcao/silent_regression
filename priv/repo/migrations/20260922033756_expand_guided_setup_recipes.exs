defmodule SilentRegression.Repo.Migrations.ExpandGuidedSetupRecipes do
  use Ecto.Migration

  def up do
    drop constraint(:guided_setup_drafts, :guided_setup_draft_shape)

    create constraint(:guided_setup_drafts, :guided_setup_draft_shape,
             check: shape("recipe IN ('routing', 'json', 'sources', 'text')")
           )
  end

  def down do
    # Preserve new-recipe history on rollback; only future writes use the old allowlist.
    drop constraint(:guided_setup_drafts, :guided_setup_draft_shape)

    execute "ALTER TABLE guided_setup_drafts ADD CONSTRAINT guided_setup_draft_shape CHECK (#{shape("recipe = 'routing'")}) NOT VALID"
  end

  defp shape(recipes) do
    "schema_version = 1 AND #{recipes} AND recipe_version = 1 AND revision > 0 AND octet_length(raw::text) <= 300000 AND octet_length(reviews::text) <= 100000 AND ((monitor_id IS NULL AND sealed_at IS NULL) OR (monitor_id IS NOT NULL AND sealed_at IS NOT NULL))"
  end
end
