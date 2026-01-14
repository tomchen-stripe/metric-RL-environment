# MRR Calculation Learnings

## Overview
This document captures learnings from implementing the MRR (Monthly Recurring Revenue) calculation using Stripe Sigma.

## Key Tables

### subscription_item_change_events
- Located in the `revenue_reporting_denorm_mrr` schema
- Contains the full history of MRR changes per subscription item
- Key columns:
  - `local_event_timestamp`: Time of change in merchant's timezone
  - `currency`: Three-letter ISO currency code
  - `mrr_change`: The MRR delta in **minor currency units** (cents/centavos)
  - `subscription_item_id`, `subscription_id`, `customer_id`, `product_id`, `price_id` for relationships

### exchange_rates_from_usd
- Contains daily mid-market exchange rates
- Key columns:
  - `date`: Date as midnight timestamp
  - `sell_currency`: Always 'usd'
  - `buy_currency_exchange_rates`: JSON object with rates for each currency

## Query Design Pattern

### 1. Baseline Calculation
Calculate cumulative MRR for each currency **before** your reporting window starts. This ensures historical MRR is accounted for.

### 2. Date Series Generation
Use `UNNEST(SEQUENCE(...))` to generate a complete series of dates for date-filling:
```sql
SELECT DATE_TRUNC('day', date) AS report_date
FROM UNNEST(SEQUENCE(start_date, end_date, INTERVAL '1' DAY)) AS t(date)
```

### 3. Currency Grid
Cross join the date series with all currencies to ensure complete coverage:
```sql
SELECT d.report_date, c.currency
FROM date_series d
CROSS JOIN all_currencies c
```

### 4. Cumulative Sum with Window Functions
Use window functions to calculate running totals:
```sql
COALESCE(baseline, 0) + SUM(daily_mrr_change) OVER (
  PARTITION BY currency
  ORDER BY report_date
  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
) AS cumulative_mrr
```

### 5. Exchange Rate Conversion
- Join with exchange rates using the previous day's rate
- For USD, use the value directly
- For other currencies, divide by the rate (since rates are USD -> currency)
- Handle NULL rates gracefully

### 6. Month-End Calculation
Calculate month_end as:
```sql
DATE_ADD('day', -1, DATE_ADD('month', 1, DATE_TRUNC('month', report_date)))
```
Note: `LAST_DAY()` function may not be available in Sigma.

### 7. Month Aggregation
Use `MAX_BY` to get the MRR value for the last day of data in each month:
```sql
MAX_BY(total_mrr_usd, report_date) AS mrr_cents
```

## Output Format
- `month_end`: Date in 'YYYY-MM-DD' format
- `total_mrr_in_usd`: MRR value in USD (divide by 100 to convert from cents)

## Key Considerations
1. MRR values in `mrr_change` are in minor currency units (cents/centavos)
2. Exchange rates are mid-market rates excluding Stripe fees
3. Using previous day's rate as specified in requirements
4. Date filling ensures continuous time series even when no changes occur
5. Baseline calculation ensures historical MRR is included

## Sigma Client Usage
The `PlainSigmaClient` class handles:
1. Creating query runs via `/v1/sigma/query_runs`
2. Polling for completion
3. Downloading CSV results
4. Parsing to JSON

## Validation
Results can be validated against `localhost:3000` by posting JSON with:
```json
{
  "metric": "mrr",
  "data": [...]
}
```
