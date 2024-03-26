#!/bin/bash

# Check if argument are okay
if [[ $# -ne 5 ]]; then
    echo "Usage: $0 <jira_api_url> <jira_api_user> <jira_api_token> <github_repo> <github_run_url>"
    exit 1
fi

# Extract arguments from command line argument
JIRA_API_URL="$1"
JIRA_API_USER="$2"
JIRA_API_TOKEN="$3"
GITHUB_REPO="$4"
GITHUB_RUN_URL="$5"

# Jira REST API endpoint to create an issue
JIRA_CREATE_ISSUE_API="$JIRA_API_URL/rest/api/latest/issue"
# Jira REST API endpoint to search for issues by JQL
JIRA_SEARCH_ISSUE_API="$JIRA_API_URL/rest/api/latest/search"
# Jira fields
JIRA_PROJECT_KEY="DP"
JIRA_PROJECT_NAME="Daniels Playground"
JIRA_ISSUE_TYPE="Bug"
JIRA_ISSUE_SUMMARY="License Check failed in $GITHUB_REPO"

# JQL query to search for issues with a specific summary
jql_query=$(printf %s "project = \"$JIRA_PROJECT_NAME\" AND summary ~ \"$JIRA_ISSUE_SUMMARY\" AND status != Done" | jq -s -R -r @uri)

# Send a GET request to Jira REST API to search for issues
response=$(curl -s -f -S -u "$JIRA_API_USER":"$JIRA_API_TOKEN" -X GET "$JIRA_SEARCH_ISSUE_API?jql=$jql_query")

# Check if the curl command was successful
if [ "$?" != 0 ]; then
  echo "Failed to search issue for $GITHUB_REPO"
  echo "JQL:"
  echo "$jql_query"
  exit 1
fi

# Check if any issues were found
total=$(echo "$response" | jq '.total')
if [[ "$total" -gt 0 ]]; then
  issue_key=$(echo "$response" | jq -r '.issues[0].key')
  echo "Issue for $GITHUB_REPO already exists with key $issue_key"

  # JSON payload for the comment
  payload=$(cat <<EOF
  {
      "body": "*Also encountered in:* $GITHUB_RUN_URL"
  }
EOF
  )

  # Send a POST request to Jira REST API to add the comment
  response=$(curl -s -f -S -u "$JIRA_API_USER":"$JIRA_API_TOKEN" -X POST -H "Content-Type: application/json" --data "$payload" "$JIRA_CREATE_ISSUE_API/$issue_key/comment")

  # Check if the curl command was successful
  if [ "$?" != 0 ];then
    echo "Failed to add comment for $GITHUB_REPO to issue with key $issue_key"
    echo "Payload:"
    echo "$payload"
    exit 1
  else
    echo "Comment added for $GITHUB_REPO to issue with key $issue_key"
  fi
else
  # Escape issue description
  issue_description="*The License Check failed in ${GITHUB_REPO}*"
  issue_description="$issue_description\\n\\n{quote}This usually means that there is an unknown or forbidden license being used.\\n\\nPlease check the build output for further details.{quote}"
  issue_description="$issue_description\\n\\n*First encountered in:* $GITHUB_RUN_URL"

  # JSON payload for creating a new issue
  payload=$(cat <<EOF
  {
      "fields": {
          "project": {
              "key": "$JIRA_PROJECT_KEY"
          },
          "summary": "$JIRA_ISSUE_SUMMARY",
          "description": "$issue_description",
          "issuetype": {
              "name": "$JIRA_ISSUE_TYPE"
          }
      }
  }
EOF
  )

  # Send a POST request to Jira REST API to create the issue
  response=$(curl -s -f -S -u "$JIRA_API_USER":"$JIRA_API_TOKEN" -X POST -H "Content-Type: application/json" --data "$payload" "$JIRA_CREATE_ISSUE_API")

  # Check if the curl command was successful
  if [ "$?" != 0 ]; then
    echo "Failed to create issue for $GITHUB_REPO"
    echo "Payload:"
    echo "$payload"
    exit 1
  fi

  # Extract the issue key from the response
  issue_key=$(echo "$response" | jq -r '.key')
  if [[ -n "$issue_key" ]]; then
    echo "Issue for $GITHUB_REPO created with key $issue_key"
  else
    echo "Failed to extract issue key for $GITHUB_REPO"
    exit 1
  fi
fi
