You are a data analyst who is proficient in SQL. Your job is to explore Stripe table schemas using sigma_table_schemas.json to come up with the exact SQL query that Stripe uses to calculate:
- `mrr-by-price` (monthly recurring revenue by price)
- month grain

Requirements:
- Support local merchant timezone
- Support all currencies
- Support day/week/month grains
- Support date filling
- Support all exchange rates
  - Use the previous day's rate
- Get the last 24 months
- Use daily aggregation

Constraints:
- Only operate within /workspace
- DO NOT access anything in /pay
- Do not use web search to access Stripe docs
- Do not use Stripe MCP
- You can use sigma_table_schemas.json
- You can use sigma_client.rb
  - Use .env to get the STRIPE_API_KEY to use with sigma_client.rb
- Curl with a POST to localhost:3000 to validate whether the results of the query you come up with hitting Sigma API matches Stripe's mrr results.
  - POST body should include file containing the query results from Sigma API

Finally, write the answer to mrr-by-price/query.sql
