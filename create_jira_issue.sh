#!/bin/bash

# Check if argument are okay
if [[ $# -ne 5 ]]; then
    echo "Usage: $0 <report_file> <jira_api_url> <jira_api_user> <jira_api_token> <github_run_url>"
    exit 1
fi

# Extract arguments from command line argument
REPORT_FILE="$1"
JIRA_API_URL="$2"
JIRA_API_USER="$3"
JIRA_API_TOKEN="$4"
GITHUB_RUN_URL="$5"

# Jira REST API endpoint to create an issue
JIRA_CREATE_ISSUE_API="$JIRA_API_URL/rest/api/latest/issue"
# Jira REST API endpoint to search for issues by JQL
JIRA_SEARCH_ISSUE_API="$JIRA_API_URL/rest/api/latest/search"


# Check if the JSON file exists
if [[ ! -f "$REPORT_FILE" ]]; then
  echo "Error: File '$REPORT_FILE' not found."
  exit 1
fi

# Extract vulnerability names and descriptions from the JSON file
vulnerabilities=$(jq -c '[.dependencies[] | select(.vulnerabilities != null) | .vulnerabilities[] | {name: .name, description: .description} ] | sort_by(.name)' "$REPORT_FILE")

# Iterate over each vulnerability object
for vulnerability in $(echo "${vulnerabilities}" | jq -r '.[] | @base64'); do
  _jq() {
    echo "${vulnerability}" | base64 --decode | jq -r "${1}"
  }

  vulnerability_name=$(_jq '.name')
  vulnerability_description=$(_jq '.description')

  # JQL query to search for issues with a specific summary
  jql_query=$(printf %s "project = \"Daniels Playground\" AND summary ~ \"$vulnerability_name\" AND status != Done" | jq -s -R -r @uri)

  # Send a GET request to Jira REST API to search for issues
  response=$(curl -s -f -S -u "$JIRA_API_USER":"$JIRA_API_TOKEN" -X GET "$JIRA_SEARCH_ISSUE_API?jql=$jql_query")

  # Check if the curl command was successful
  if [ "$?" != 0 ]; then
    echo "Failed to search issue for $vulnerability_name"
    echo "JQL:"
    echo "$jql_query"
    exit 1
  fi

  # Check if any issues were found
  total=$(echo "$response" | jq '.total')
  if [[ "$total" -gt 0 ]]; then
    issue_key=$(echo "$response" | jq -r '.issues[0].key')
    echo "Issue for $vulnerability_name already exists. Key: $issue_key"
  else
    # Escape issue description
    issue_description=${vulnerability_description//$'\n'/\\n}
    issue_description=${issue_description//$'\"'/}
    issue_description="*National Vulnerability Database:* https://nvd.nist.gov/vuln/detail/$vulnerability_name\\n\\n{quote}$issue_description{quote}"
    issue_description="$issue_description\\n\\n*First encountered in: $GITHUB_RUN_URL"

    # Escape issue summary
    issue_summary=${vulnerability_description//$'\n'/ }
    issue_summary=${issue_summary//$'\"'/}
    issue_summary=$(echo "$vulnerability_name - $issue_summary" | sed "s/\(.\{250\}\).*/\1 .../")

    # JSON payload for creating a new issue
    payload=$(cat <<EOF
    {
        "fields": {
            "project": {
                "key": "DP"
            },
            "summary": "$issue_summary",
            "description": "$issue_description",
            "issuetype": {
                "name": "Bug"
            }
        }
    }
EOF
    )

    # Send a POST request to Jira REST API to create the issue
    response=$(curl -s -f -S -u "$JIRA_API_USER":"$JIRA_API_TOKEN" -X POST -H "Content-Type: application/json" --data "$payload" "$JIRA_CREATE_ISSUE_API")

    # Check if the curl command was successful
    if [ "$?" != 0 ]; then
      echo "Failed to create issue for $vulnerability_name"
      echo "Payload:"
      echo "$payload"
      exit 1
    fi

    # Extract the issue key from the response
    issue_key=$(echo "$response" | jq -r '.key')
    if [[ -n "$issue_key" ]]; then
      echo "Issue created with key $issue_key"
    else
      echo "Failed to extract issue key for $vulnerability_name"
      exit 1
    fi
  fi
done
