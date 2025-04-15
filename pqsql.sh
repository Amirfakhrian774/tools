#!/bin/bash

# PostgreSQL container name
POSTGRES_CONTAINER_NAME="my_postgres_db"
# Default PostgreSQL user for executing commands
POSTGRES_USER="admin_user"

# Function to create a database
create_database() {
  read -p "Enter the new database name: " NEW_DATABASE_NAME
  docker exec -it "$POSTGRES_CONTAINER_NAME" psql -h localhost -U "$POSTGRES_USER" -d "postgres" -c "CREATE DATABASE \"$NEW_DATABASE_NAME\";"
  if [ $? -eq 0 ]; then
    echo "Database \"$NEW_DATABASE_NAME\" created successfully."
  else
    echo "Error creating database \"$NEW_DATABASE_NAME\"."
  fi
}

# Function to execute a query
execute_query() {
  read -p "Enter the database name to connect to: " DATABASE_NAME
  read -p "Enter the SQL query to execute: " SQL_QUERY
  docker exec -it "$POSTGRES_CONTAINER_NAME" psql -U "$POSTGRES_USER" -d "$DATABASE_NAME" -c "$SQL_QUERY"
}

# Function to list databases
list_databases() {
  echo "Listing available databases:"
  docker exec "$POSTGRES_CONTAINER_NAME" psql -h localhost -U "$POSTGRES_USER" -l
}

# Function to create a user with custom permissions
create_user() {
  read -p "Enter the new username: " NEW_USERNAME
  read -s -p "Enter the password for the new user: " NEW_PASSWORD
  echo ""
  read -s -p "Confirm the password: " CONFIRM_PASSWORD
  echo ""

  if [ "$NEW_PASSWORD" != "$CONFIRM_PASSWORD" ]; then
    echo "Passwords do not match. User creation aborted."
    return 1
  fi

  # List existing databases using the working function
  echo "Available databases (raw output):"
  echo "Executing: docker exec \"$POSTGRES_CONTAINER_NAME\" psql -h localhost -U \"$POSTGRES_USER\" -l"
  ALL_DATABASES=$(docker exec "$POSTGRES_CONTAINER_NAME" psql -h localhost -U "$POSTGRES_USER" -l)
  echo "$ALL_DATABASES"

  # Extract database names - Simplified approach
  DATABASES=$(echo "$ALL_DATABASES" | awk 'NR>2 && $1 != "" && $1 != "(no" {print $1}')

  echo "Extracted database names: $DATABASES"

  read -p "Enter the database name to grant access on (or '*' for all): " TARGET_DATABASE

  read -p "Grant read (SELECT) access? (y/n): " READ_ACCESS
  read -p "Grant write (INSERT) access? (y/n): " WRITE_ACCESS
  read -p "Grant update access? (y/n): " UPDATE_ACCESS
  read -p "Grant delete access? (y/n): " DELETE_ACCESS

  echo "Creating user \"$NEW_USERNAME\"..."
  docker exec -it "$POSTGRES_CONTAINER_NAME" psql -h localhost -U "$POSTGRES_USER" -d "postgres" -c "CREATE USER \"$NEW_USERNAME\" WITH PASSWORD '$NEW_PASSWORD';"

  if [ "$TARGET_DATABASE" == "*" ]; then
    DATABASE_LIST=$(echo "$DATABASES")
  else
    DATABASE_LIST="$TARGET_DATABASE"
  fi

  for DB in $DATABASE_LIST; do
    if [ -n "$DB" ]; then
      echo "Granting permissions on database: $DB"
      docker exec -it "$POSTGRES_CONTAINER_NAME" psql -h localhost -U "$POSTGRES_USER" -d "$DB" -c "GRANT CONNECT ON DATABASE \"$DB\" TO \"$NEW_USERNAME\";"

      GRANT_STATEMENTS=""
      if [[ "$READ_ACCESS" == "y" ]]; then
        GRANT_STATEMENTS+="GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"$NEW_USERNAME\"; "
      fi
      if [[ "$WRITE_ACCESS" == "y" ]]; then
        GRANT_STATEMENTS+="GRANT INSERT ON ALL TABLES IN SCHEMA public TO \"$NEW_USERNAME\"; "
      fi
      if [[ "$UPDATE_ACCESS" == "y" ]]; then
        GRANT_STATEMENTS+="GRANT UPDATE ON ALL TABLES IN SCHEMA public TO \"$NEW_USERNAME\"; "
      fi
      if [[ "$DELETE_ACCESS" == "y" ]]; then
        GRANT_STATEMENTS+="GRANT DELETE ON ALL TABLES IN SCHEMA public TO \"$NEW_USERNAME\"; "
      fi

      if [ -n "$GRANT_STATEMENTS" ]; then
        docker exec -it "$POSTGRES_CONTAINER_NAME" psql -U "$POSTGRES_USER" -d "$DB" -c "$GRANT_STATEMENTS"
      fi
    fi
  done

  echo "User \"$NEW_USERNAME\" created with specified permissions."
}

# Function to view user permissions (Database Level) - Using pg_catalog
view_user_permissions() {
  echo "Listing User Permissions (Name / Database / Level):"
  docker exec "$POSTGRES_CONTAINER_NAME" psql -h localhost -U "$POSTGRES_USER" -d "postgres" -t -A -F $'\t' -c "
    SELECT
      pg_authid.rolname AS grantee,
      pg_database.datname AS database_name,
      'CONNECT' AS privilege_type
    FROM
      pg_database
    CROSS JOIN
      pg_authid
    LEFT JOIN
      pg_db_role_setting ON (pg_db_role_setting.setdatabase = pg_database.oid AND pg_db_role_setting.setrole = pg_authid.oid)
    WHERE
      pg_authid.rolname <> 'postgres'
    ORDER BY
      grantee,
      database_name;
  " | while IFS=$'\t' read -r grantee database_name privilege_type; do
    if [[ -n "$grantee" ]]; then
      echo " ${grantee} / ${database_name} / ${privilege_type}"
    fi
  done
}

# Function to view table permissions (Simplified query)
view_table_permissions() {
  echo "Listing Table Permissions (User / Table / Level - First 5):"
  docker exec "$POSTGRES_CONTAINER_NAME" psql -h localhost -U "$POSTGRES_USER" -d "postgres" -t -A -F $'\t' -c "SELECT grantee, table_name, privilege_type FROM information_schema.role_table_grants LIMIT 5;" | while IFS=$'\t' read -r grantee table_name privilege_type; do
    echo " ${grantee} / ${table_name} / ${privilege_type}"
  done
}

# Main menu
while true; do
  echo ""
  echo "PostgreSQL Management Menu"
  echo "-------------------------"
  echo "1. Create Database"
  echo "2. Execute Query"
  echo "3. Create User"
  echo "4. Exit"
  echo "5. List Databases"
  echo "6. View User Permissions (Database Level)"
  echo "7. View Table Permissions"
  read -p "Enter your choice (1-7): " CHOICE

  case "$CHOICE" in
    1)
      create_database
      ;;
    2)
      execute_query
      ;;
    3)
      create_user
      ;;
    4)
      echo "Exiting..."
      break
      ;;
    5)
      list_databases
      ;;
    6)
      view_user_permissions
      ;;
    7)
      view_table_permissions
      ;;
    *)
      echo "Invalid choice. Please enter a number between 1 and 7."
      ;;
  esac
done