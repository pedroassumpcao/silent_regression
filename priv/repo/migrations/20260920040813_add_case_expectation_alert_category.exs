defmodule SilentRegression.Repo.Migrations.AddCaseExpectationAlertCategory do
  use Ecto.Migration

  def up do
    drop constraint(:result_alerts, :result_alerts_category_check)

    create constraint(:result_alerts, :result_alerts_category_check,
             check:
               "category IN ('contract_failure', 'case_expectation_failure', 'operational_anomaly')"
           )
  end

  def down do
    drop constraint(:result_alerts, :result_alerts_category_check)

    create constraint(:result_alerts, :result_alerts_category_check,
             check: "category IN ('contract_failure', 'operational_anomaly')"
           )
  end
end
