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
