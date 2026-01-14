FROM ubuntu:24.04

WORKDIR /app

# Copy server and data files
COPY server.js .
COPY *.json .
COPY answers/ ./answers/

EXPOSE 3000

CMD ["/usr/stripe/nodenv/nodenv-1.1.2/shims/node", "server.js"]
