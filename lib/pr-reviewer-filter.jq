# pr-reviewer-filter.jq — filter a `search { nodes { ...PullRequest } }` graphql
# response to PRs that need review by $bot.
#
# Inputs (via --arg): bot, owner, name
# Output: JSON array of {number,title,url,headRefName,baseRefName,headSha,author,owner,name,botUser}

[.data.search.nodes[]
  | select(.isDraft == false)
  | select(.commits.nodes[0].commit.statusCheckRollup.state == "SUCCESS")
  | (.commits.nodes[0].commit.committedDate // "1970-01-01T00:00:00Z") as $lastCommit
  | ([.latestReviews.nodes[] | select(.author.login == $bot) | .submittedAt] | max // "1970-01-01T00:00:00Z") as $myLastReview
  | select($lastCommit > $myLastReview)
  | {
      number,
      title,
      url,
      headRefName,
      baseRefName,
      headSha: .commits.nodes[0].commit.oid,
      author: .author.login,
      owner: $owner,
      name: $name,
      botUser: $bot
    }
]
