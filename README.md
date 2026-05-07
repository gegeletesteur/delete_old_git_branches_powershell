# Delete old git branches on Windows
---
Script to be executed within VScode when connected to a GitHub repository via the Remote Repositories extension. 
It uses the gh CLI and GitHub GraphQL API to identify and delete branches that meet certain criteria.
Use: Will be deleting branches in a GitHub repository that have no open PRs, are not protected, and whose last commit is older than 2 months
