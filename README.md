# Use an agent to reverse engineer how Stripe calculates a metric (e.g. MRR)

This project sets up a reinforcement learning (RL) environment for an AI agent like Claude Code to reverse engineer how Stripe calculates a metric like MRR using two isolated containers:

1. The "explorer" which has access to:
   - a requirements prompt ([explorer/prompts/mrr.md](explorer/prompts/mrr.md))
   - sigma client to query Sigma API ([sigma_client.rb](explorer/sigma_client.rb))
   - sigma table schemas ([sigma_table_schemas.json](explorer/sigma_table_schemas.json))
   - a prompt describing the requirements for the metric ([explorer/prompts/mrr.md](explorer/prompts/mrr.md))
2. The "validator" that returns pass/fail to the explorer based on whether the SQL query that it is coming up with matches the results Stripe returns from Sigma Templates and Sigma API

Both the explorer and validator run in their own docker container to isolate them from finding a way to access the answers (Sigma Template for MRR).

NOTE: For the explorer, I needed to mount `/pay` to get `claude` working in the docker container, but I added instructions in `CLAUDE.md` to prevent it from accessing `/pay`. You can also verify in Claude logs that it does not access that repo.

## Installation

1. Add a STRIPE_API_KEY to `explorer/.env` with these API permissions:

- Sigma API: write
- Reporting API: write
- Files API: read

2. Restart docker:

```
sudo systemctl restart containerd
sudo systemctl restart docker

docker compose up --build -d
docker exec -it explorer bash
```

3. Run docker compose and exec into the "explorer" container:
```
docker compose up --build -d
docker exec -it explorer bash
```

## Run Claude Code in an isolated container:
```
claude --dangerously-skip-permissions
```

## Prompt Claude to reverse engineer the SQL for a Stripe metric (e.g. mrr):
```
"read prompts/mrr.md and follow it"
```

# Results

The agent is able to reverse engineer our most complex Sigma Template (MRR) in about 10 minutes and match the returned values exactly. The SQL design is semantically very close to how we define it.

Agent discovered MRR SQL:

<details>
<summary>Click to expand SQL</summary>

```sql
-- MRR (Monthly Recurring Revenue) Query
-- Requirements:
-- - Support local merchant timezone (using local_event_timestamp)
-- - Support all currencies (converted to USD)
-- - Support day/week/month grains (month grain for this query)
-- - Support date filling
-- - Support all exchange rates (using previous day's rate from reporting date)
-- - Get the last 24 months
-- - Use daily aggregation

WITH
-- Get all unique currencies from historical data
all_currencies AS (
  SELECT DISTINCT currency FROM subscription_item_change_events
),

-- Calculate the baseline MRR before the 25-month window (per currency)
baseline_mrr AS (
  SELECT
    currency,
    COALESCE(SUM(mrr_change), 0) AS baseline
  FROM
    subscription_item_change_events
  WHERE
    local_event_timestamp < DATE_TRUNC('month', CURRENT_DATE - INTERVAL '25' MONTH)
  GROUP BY
    currency
),

-- Daily MRR changes by currency within the window
daily_mrr_changes AS (
  SELECT
    DATE_TRUNC('day', local_event_timestamp) AS change_date,
    currency,
    SUM(mrr_change) AS daily_mrr_change
  FROM
    subscription_item_change_events
  WHERE
    local_event_timestamp >= DATE_TRUNC('month', CURRENT_DATE - INTERVAL '25' MONTH)
  GROUP BY
    DATE_TRUNC('day', local_event_timestamp),
    currency
),

-- Generate a series of dates for the window
date_series AS (
  SELECT
    DATE_TRUNC('day', date) AS report_date
  FROM
    UNNEST(SEQUENCE(
      DATE_TRUNC('month', CURRENT_DATE - INTERVAL '25' MONTH),
      DATE_TRUNC('day', CURRENT_DATE),
      INTERVAL '1' DAY
    )) AS t(date)
),

-- Create a grid of dates x currencies
date_currency_grid AS (
  SELECT
    d.report_date,
    c.currency
  FROM
    date_series d
  CROSS JOIN
    all_currencies c
),

-- Fill in missing dates with 0 changes
filled_daily_changes AS (
  SELECT
    g.report_date,
    g.currency,
    COALESCE(m.daily_mrr_change, 0) AS daily_mrr_change
  FROM
    date_currency_grid g
  LEFT JOIN
    daily_mrr_changes m
    ON g.report_date = m.change_date
    AND g.currency = m.currency
),

-- Calculate cumulative MRR by currency, adding baseline
cumulative_mrr_by_currency AS (
  SELECT
    f.report_date,
    f.currency,
    COALESCE(b.baseline, 0) + SUM(f.daily_mrr_change) OVER (
      PARTITION BY f.currency
      ORDER BY f.report_date
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_mrr
  FROM
    filled_daily_changes f
  LEFT JOIN
    baseline_mrr b ON f.currency = b.currency
),

-- Get exchange rates
exchange_rates AS (
  SELECT
    date AS rate_date,
    buy_currency_exchange_rates
  FROM
    exchange_rates_from_usd
),

-- Join with exchange rates (using previous day's rate)
mrr_with_rates AS (
  SELECT
    c.report_date,
    c.currency,
    c.cumulative_mrr,
    e.buy_currency_exchange_rates
  FROM
    cumulative_mrr_by_currency c
  LEFT JOIN
    exchange_rates e
    ON e.rate_date = DATE_TRUNC('day', c.report_date - INTERVAL '1' DAY)
),

-- Convert MRR to USD using exchange rates
mrr_in_usd AS (
  SELECT
    report_date,
    currency,
    cumulative_mrr,
    CASE
      WHEN currency = 'usd' THEN CAST(cumulative_mrr AS DOUBLE)
      WHEN buy_currency_exchange_rates IS NULL THEN 0.0
      ELSE CAST(cumulative_mrr AS DOUBLE) / CAST(JSON_EXTRACT_SCALAR(buy_currency_exchange_rates, CONCAT('$.', currency)) AS DOUBLE)
    END AS cumulative_mrr_usd
  FROM
    mrr_with_rates
),

-- Daily aggregation - sum all currencies converted to USD
daily_mrr AS (
  SELECT
    report_date,
    SUM(cumulative_mrr_usd) AS total_mrr_usd
  FROM
    mrr_in_usd
  GROUP BY
    report_date
),

-- Month grain aggregation - get the MRR at the last day we have data for each month
month_last_day AS (
  SELECT
    DATE_TRUNC('month', report_date) AS month_start,
    MAX(report_date) AS last_data_date,
    MAX_BY(total_mrr_usd, report_date) AS mrr_cents
  FROM
    daily_mrr
  GROUP BY
    DATE_TRUNC('month', report_date)
),

monthly_mrr AS (
  SELECT
    DATE_ADD('day', -1, DATE_ADD('month', 1, month_start)) AS month_end,
    mrr_cents
  FROM
    month_last_day
)

SELECT
  CAST(month_end AS VARCHAR) AS month_end,
  FORMAT('%.2f', mrr_cents / 100.0) AS total_mrr_in_usd
FROM
  monthly_mrr
ORDER BY
  month_end DESC
```

</details>

vs

Stripe defined Sigma Template for MRR:

<details>
<summary>Click to expand SQL</summary>

```sql
WITH sparse_mrr_changes AS (
          SELECT
            DATE_TRUNC(
              'day',
              DATE(local_event_timestamp)
            ) AS date,
            currency,
            SUM(mrr_change) AS mrr_change_on_day
          FROM
            subscription_item_change_events
          GROUP BY
            1,
            2
        ),
        sparse_mrrs AS (
          SELECT
            date,
            currency,
            mrr_change_on_day,
            SUM(mrr_change_on_day) OVER (
              PARTITION BY currency
              ORDER BY
                date ASC
            ) AS mrr
          FROM
            sparse_mrr_changes
          ORDER BY
            currency,
            date DESC
        ),
        -- Prepare the multi dimensional table,
        -- note that exchange_rates_from_usd contains one row for every date from 2010-01-07 until today
        -- which is why we don't need to generate a separate date series for the full table
        fx AS (
          SELECT
            date - INTERVAL '1' DAY AS date,
            CAST(
              JSON_PARSE(buy_currency_exchange_rates) AS MAP(VARCHAR, DOUBLE)
            ) AS rate_per_usd
          FROM
            exchange_rates_from_usd
        ),
        currencies AS (
          SELECT DISTINCT currency
          FROM subscription_item_change_events
        ),
        -- Joining mrr_changes against the master table and get running sum
        date_currency AS (
          SELECT
            date,
            rate_per_usd,
            currency
          FROM
            fx
            CROSS JOIN currencies
          ORDER BY
            date,
            currency
        ),
        date_currency_mrr AS (
          SELECT
            dpc.date,
            dpc.currency,
            dpc.rate_per_usd,
            mrr_change_on_day,
            mrr AS _mrr,
            LAST_VALUE(mrr) IGNORE NULLS OVER (
              PARTITION BY dpc.currency
              ORDER BY
                dpc.date ASC
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS mrr
          FROM
            date_currency dpc
            LEFT JOIN sparse_mrrs sm
              ON dpc.date = sm.date
             AND dpc.currency = sm.currency
        ),
        daily_mrrs_pre_fx AS (
          SELECT
            date,
            currency,
            rate_per_usd,
            SUM(mrr) AS mrr
          FROM
            date_currency_mrr
          GROUP BY
            1,
            2,
            3
          ORDER BY
            date DESC
        ),
        daily_mrrs AS (
          SELECT
            date,
            -- change 'usd' below to the currency you want your report in
            SUM(ROUND(mrr / rate_per_usd[currency] * rate_per_usd['usd'])) AS total_mrr_in_usd_minor_units
          FROM
            daily_mrrs_pre_fx
          GROUP BY 1
        ),
        daily_mrrs_display AS (
          SELECT
            date,
            -- convert from minor units to decimal
            DECIMALIZE_AMOUNT_NO_DISPLAY('usd', total_mrr_in_usd_minor_units, 2) AS total_mrr_in_usd
          FROM
            daily_mrrs
          WHERE
            -- same 24‑month window as the monthly query (start of month 24 months ago)
            date >= CAST(DATE_FORMAT(CURRENT_DATE, '%Y-%m-01') AS date) - INTERVAL '24' MONTH
        )

        SELECT
          *
        FROM
          daily_mrrs_display
        ORDER BY
          date DESC;

```

</details>