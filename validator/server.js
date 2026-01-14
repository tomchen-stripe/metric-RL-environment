const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 3000;

// Function to load expected results based on metric
function loadExpectedResults(metric) {
  const validMetrics = ['mrr', 'mrr-by-price'];
  if (!validMetrics.includes(metric)) {
    throw new Error(`Invalid metric: ${metric}. Valid metrics are: ${validMetrics.join(', ')}`);
  }
  const resultsFile = path.join(__dirname, `${metric}.json`);
  return JSON.parse(fs.readFileSync(resultsFile, 'utf8'));
}

// Deep equality comparison
function deepEqual(obj1, obj2) {
  if (obj1 === obj2) return true;

  if (obj1 == null || obj2 == null) return false;
  if (typeof obj1 !== 'object' || typeof obj2 !== 'object') return false;

  const keys1 = Object.keys(obj1);
  const keys2 = Object.keys(obj2);

  if (keys1.length !== keys2.length) return false;

  for (const key of keys1) {
    if (!keys2.includes(key)) return false;
    if (!deepEqual(obj1[key], obj2[key])) return false;
  }

  return true;
}

const server = http.createServer((req, res) => {
  // Set CORS headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Content-Type', 'application/json');

  // Handle OPTIONS preflight
  if (req.method === 'OPTIONS') {
    res.writeHead(200);
    res.end();
    return;
  }

  // Handle GET requests - return expected schema
  if (req.method === 'GET') {
    const schema = {
      description: 'Expected input schema for POST validation',
      type: 'object',
      required: ['metric', 'grain', 'data', 'columns', 'pivot'],
      properties: {
        metric: {
          type: 'string',
          description: 'The metric being measured',
          enum: ['mrr', 'mrr-by-price'],
          example: 'mrr'
        },
        grain: {
          type: 'string',
          description: 'The time granularity',
          example: 'month'
        },
        data: {
          type: 'array',
          description: 'Array of data points',
          items: {
            type: 'object',
            properties: {
              month_end: {
                type: 'string',
                description: 'End date of the month in YYYY-MM-DD format',
                example: '2025-12-31'
              },
              total_mrr_in_usd: {
                type: 'string',
                description: 'Total MRR in USD',
                example: '1110902.02'
              }
            }
          }
        },
        columns: {
          type: 'array',
          description: 'Column names',
          items: {
            type: 'string'
          },
          example: ['month_end', 'total_mrr_in_usd']
        },
        pivot: {
          type: 'object',
          description: 'Pivot configuration',
          properties: {
            colKey: {
              type: 'string',
              description: 'Column key for pivot',
              example: 'month_end'
            },
            valueKey: {
              type: 'string',
              description: 'Value key for pivot',
              example: 'total_mrr_in_usd'
            }
          }
        }
      }
    };
    res.writeHead(200);
    res.end(JSON.stringify(schema, null, 2));
    return;
  }

  // Only accept POST requests for validation
  if (req.method !== 'POST') {
    res.writeHead(405);
    res.end(JSON.stringify({ error: 'Method not allowed. Use GET for schema or POST for validation.' }));
    return;
  }

  let body = '';

  req.on('data', chunk => {
    body += chunk.toString();
  });

  req.on('end', () => {
    try {
      const receivedData = JSON.parse(body);

      // Extract metric from request
      if (!receivedData.metric) {
        res.writeHead(400);
        res.end(JSON.stringify({
          status: 'fail',
          error: 'Missing metric field',
          message: 'Request must include a metric field (mrr or mrr-by-price)'
        }));
        return;
      }

      // Load expected results for the specified metric
      let expectedResults;
      try {
        expectedResults = loadExpectedResults(receivedData.metric);
      } catch (error) {
        res.writeHead(400);
        res.end(JSON.stringify({
          status: 'fail',
          error: 'Invalid metric',
          message: error.message
        }));
        return;
      }

      const isEqual = deepEqual(receivedData, expectedResults);

      if (isEqual) {
        res.writeHead(200);
        res.end(JSON.stringify({
          status: 'success',
          message: `Data matches ${receivedData.metric}.json`,
          results: expectedResults
        }));
      } else {
        res.writeHead(200);
        res.end(JSON.stringify({
          status: 'fail',
          message: `Data does not match ${receivedData.metric}.json`,
          results: expectedResults
        }));
      }
    } catch (error) {
      res.writeHead(400);
      res.end(JSON.stringify({
        status: 'fail',
        error: 'Invalid JSON',
        message: error.message
      }));
    }
  });
});

server.listen(PORT, () => {
  console.log(`Validator server running on http://localhost:${PORT}`);
  console.log(`GET  / - Retrieve expected input schema`);
  console.log(`POST / - Validate JSON data against results.json`);
});
