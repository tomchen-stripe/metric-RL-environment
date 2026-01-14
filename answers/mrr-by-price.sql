-- This template returns total monthly recurring revenue by price
-- Cross dimensional grouping
WITH sparse_mrr_changes AS (
  SELECT
    DATE_TRUNC(
      'day',
      DATE(local_event_timestamp)
    ) AS date,
    currency,
    product_id,
    price_id,
    SUM(mrr_change) AS mrr_change_on_day
  FROM
    subscription_item_change_events_v2_beta
  GROUP BY
    1,
    2,
    3,
    4
),
sparse_mrrs AS (
  SELECT
    date,
    currency,
    product_id,
    price_id,
    mrr_change_on_day,
    SUM(mrr_change_on_day) OVER (
      PARTITION BY
        currency,
        product_id,
        price_id
      ORDER BY
        date asc
    ) AS mrr
  FROM
    sparse_mrr_changes
  ORDER BY
    product_id,
    price_id,
    currency,
    date DESC
),
-- Prepare the multi dimensional table,
-- note that exchange_rates_from_usd contains one row for every date from 2010-01-07 until today
-- which is why we don't need to generate a separate date series for the full table
fx AS (
  SELECT
    date - INTERVAL '1' DAY AS date,
    cast(
      JSON_PARSE(buy_currency_exchange_rates) as MAP(VARCHAR, DOUBLE)
    ) AS rate_per_usd
  FROM
    exchange_rates_from_usd
),
segments AS (
  SELECT
    DISTINCT product_id, price_id
  FROM
    subscription_item_change_events_v2_beta
),
currencies AS (
  SELECT
    DISTINCT(currency)
  FROM
    subscription_item_change_events_v2_beta
),
-- Joining mrr_changes against the master table and get running sum
date_segment_currency AS (
  SELECT
    date,
    rate_per_usd,
    product_id,
    price_id,
    currency
  FROM
    fx
    CROSS JOIN segments
    CROSS JOIN currencies
  ORDER BY
    date,
    currency,
    product_id,
    price_id
),
date_segment_currency_mrr AS (
  SELECT
    dsc.date,
    dsc.product_id,
    dsc.price_id,
    dsc.currency,
    dsc.rate_per_usd,
    mrr_change_on_day,
    mrr as _mrr,
    LAST_VALUE(mrr) IGNORE NULLS OVER (
      PARTITION BY
        dsc.product_id,
        dsc.price_id,
        dsc.currency
      ORDER BY
        dsc.date ASC
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS mrr
  FROM
    date_segment_currency dsc
  LEFT JOIN sparse_mrrs sm ON dsc.date = sm.date
    AND dsc.product_id = sm.product_id
    AND dsc.price_id = sm.price_id
    AND dsc.currency = sm.currency
),
daily_mrrs_pre_fx AS (
  SELECT
    date,
    product_id,
    price_id,
    currency,
    rate_per_usd,
    SUM(mrr) AS mrr
  FROM
    date_segment_currency_mrr
  GROUP BY
    1,
    2,
    3,
    4,
    5
  ORDER BY
    date DESC
),
daily_mrrs as (
  SELECT
    date,
    product_id,
    price_id,
    -- change usd below to the currency you want your report in
    SUM(ROUND(mrr / rate_per_usd [currency] * rate_per_usd ['usd'])) as total_mrr_in_usd_minor_units
  FROM
    daily_mrrs_pre_fx
  GROUP BY
    1,
    2,
    3
),
-- Pick last day of the month for the monthly MRRs
-- can be either 24 or 25 month at the moment...
months as (
  SELECT
    date_col - (INTERVAL '1' DAY) AS month_end
  FROM
    UNNEST(
      SEQUENCE(
        CAST(DATE_FORMAT(CURRENT_DATE, '%Y-%m-01') AS date) - INTERVAL '24' MONTH,
        CURRENT_DATE,
        INTERVAL '1' MONTH
      )
    ) t (date_col)
),
monthly_mrrs as (
  SELECT
    month_end,
    dm.product_id,
    dm.price_id,
    -- change usd below to the currency you want your report in
    DECIMALIZE_AMOUNT_NO_DISPLAY('usd', dm.total_mrr_in_usd_minor_units, 2) AS total_mrr_in_usd
  FROM
    months m
  LEFT JOIN daily_mrrs dm ON m.month_end = dm.date
  ORDER BY
    1 DESC,
    4 DESC,
    2,
    3
)
SELECT
  prod.name AS product_name,
  pri.nickname AS price_nickname,
  *
FROM
  monthly_mrrs mrr
JOIN products prod ON
  mrr.product_id = prod.id
JOIN prices pri ON
	mrr.price_id = pri.id
  AND mrr.product_id = pri.product_id
