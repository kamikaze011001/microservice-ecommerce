#!/bin/bash
# init-mongo.sh - MongoDB initialization script

set -e

# Connection parameters
HOST="ecommerce-mongodb"
PORT="27017"
USERNAME="$MONGO_USERNAME"
PASSWORD="$MONGO_PASSWORD"
AUTH_DB="admin"
DB_NAME="$MONGO_DB_NAME"

echo "Starting MongoDB initialization..."

# Function to safely run mongo commands
run_mongo_command() {
  mongosh --host $HOST:$PORT -u $USERNAME -p $PASSWORD --authenticationDatabase $AUTH_DB --eval "$1"
}

# Try to initialize the replica set
initialize_replica_set() {
  echo "Attempting to initialize replica set..."
  run_mongo_command 'try { rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "ecommerce-mongodb:27017", priority: 1 }] }); } catch (err) { if (err.codeName !== "AlreadyInitialized") { print("Error: " + err.message); } else { print("Replica set already initialized."); } }'
}

# Wait for primary
wait_for_primary() {
  echo "Waiting for node to become primary..."
  MAX_ATTEMPTS=60
  ATTEMPTS=0

  while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    IS_PRIMARY=$(run_mongo_command 'try { if (rs.isMaster().ismaster) { print("true"); } else { print("false"); } } catch(err) { print("false"); }')

    if [[ $IS_PRIMARY == *"true"* ]]; then
      echo "Node is now PRIMARY!"
      return 0
    else
      echo "Waiting for PRIMARY state... ($((ATTEMPTS+1))/$MAX_ATTEMPTS)"
      sleep 2
      ATTEMPTS=$((ATTEMPTS+1))
    fi
  done

  echo "Failed to become primary within timeout period."
  return 1
}

# Setup database and user
setup_database() {
  echo "Granting permissions..."
  run_mongo_command "db = db.getSiblingDB('admin'); db.grantRolesToUser('$USERNAME', [{ role: 'readWrite', db: '$DB_NAME' }]);"

  echo "Permissions granted and setup complete!"
}

# Final status check
check_status() {
  echo "Final replica set status:"
  run_mongo_command "rs.status()"
}

# Main execution
initialize_replica_set
if wait_for_primary; then
  setup_database
  check_status
  echo "MongoDB initialization completed successfully!"
else
  echo "MongoDB initialization failed - could not establish primary status."
  exit 1
fi