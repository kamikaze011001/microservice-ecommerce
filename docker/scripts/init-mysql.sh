#!/bin/bash

# MySQL Replication Initialization Script
# This script configures replication between master and slave nodes
# It should be placed in ./scripts/init-mysql.sh

set -e

echo "Starting MySQL replication setup..."

# Wait an additional moment to ensure all MySQL servers are fully available
sleep 10

# Setup database and replication user on master
echo "Setting up database and replication user on master..."
mysql -h master -uroot -p"$MYSQL_MASTER_PASSWORD" -e "
CREATE DATABASE IF NOT EXISTS ecommerce_dev;
CREATE USER IF NOT EXISTS '$MYSQL_REPL_USER'@'%' IDENTIFIED WITH mysql_native_password BY '$MYSQL_REPL_PASSWORD';
GRANT REPLICATION SLAVE ON *.* TO '$MYSQL_REPL_USER'@'%';
-- ProxySQL (ADR 0012). Created on the master so they replicate to both slaves:
-- ProxySQL logs into EVERY backend with the same credentials, and each slave's
-- root password is its own (MYSQL_SLAVEn_PASSWORD), so root can't be that user.
CREATE USER IF NOT EXISTS '$MYSQL_APP_USER'@'%' IDENTIFIED WITH mysql_native_password BY '$MYSQL_APP_PASSWORD';
GRANT ALL PRIVILEGES ON ecommerce_dev.* TO '$MYSQL_APP_USER'@'%';
CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED WITH mysql_native_password BY '$PROXYSQL_MONITOR_PASSWORD';
GRANT USAGE, REPLICATION CLIENT ON *.* TO 'monitor'@'%';
FLUSH PRIVILEGES;
"

# Configure and start replication on slave1
echo "Configuring slave1..."
# STOP + RESET first: the relay log is named after the container's hostname, so
# a recreated container can't find the old one and CHANGE MASTER fails with
# ERROR 1872 on every later `make up`. RESET drops only relay state; with
# MASTER_AUTO_POSITION the slave resumes from its own GTID set.
mysql -h slave1 -uroot -p"$MYSQL_SLAVE1_PASSWORD" -e "
STOP SLAVE;
RESET SLAVE;
CHANGE MASTER TO
  MASTER_HOST='master',
  MASTER_USER='$MYSQL_REPL_USER',
  MASTER_PASSWORD='$MYSQL_REPL_PASSWORD',
  MASTER_AUTO_POSITION=1;
START SLAVE;
"

# Check slave1 status
echo "Checking slave1 status..."
slave1_status=$(mysql -h slave1 -uroot -p"$MYSQL_SLAVE1_PASSWORD" -e "SHOW SLAVE STATUS\G")
if echo "$slave1_status" | grep -q "Slave_IO_Running: Yes" && echo "$slave1_status" | grep -q "Slave_SQL_Running: Yes"; then
    echo "Slave1 replication started successfully."
else
    echo "Error: Slave1 replication failed to start properly:"
    echo "$slave1_status" | grep -E "Slave_IO_Running:|Slave_SQL_Running:|Last_IO_Error:|Last_SQL_Error:"
    exit 1
fi

# Configure and start replication on slave2
echo "Configuring slave2..."
# STOP + RESET first: the relay log is named after the container's hostname, so
# a recreated container can't find the old one and CHANGE MASTER fails with
# ERROR 1872 on every later `make up`. RESET drops only relay state; with
# MASTER_AUTO_POSITION the slave resumes from its own GTID set.
mysql -h slave2 -uroot -p"$MYSQL_SLAVE2_PASSWORD" -e "
STOP SLAVE;
RESET SLAVE;
CHANGE MASTER TO
  MASTER_HOST='master',
  MASTER_USER='$MYSQL_REPL_USER',
  MASTER_PASSWORD='$MYSQL_REPL_PASSWORD',
  MASTER_AUTO_POSITION=1;
START SLAVE;
"

# Check slave2 status
echo "Checking slave2 status..."
slave2_status=$(mysql -h slave2 -uroot -p"$MYSQL_SLAVE2_PASSWORD" -e "SHOW SLAVE STATUS\G")
if echo "$slave2_status" | grep -q "Slave_IO_Running: Yes" && echo "$slave2_status" | grep -q "Slave_SQL_Running: Yes"; then
    echo "Slave2 replication started successfully."
else
    echo "Error: Slave2 replication failed to start properly:"
    echo "$slave2_status" | grep -E "Slave_IO_Running:|Slave_SQL_Running:|Last_IO_Error:|Last_SQL_Error:"
    exit 1
fi

echo "MySQL master-slave replication setup complete!"