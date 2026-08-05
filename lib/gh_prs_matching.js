import { auth, repoResolve, rateLimitCheck } from './shared.js';

export function gh_prs_matching(spec) {
  const authToken = auth();
  const repo = repoResolve();
  if (!rateLimitCheck()) return [];

  const query = buildQueryFromSpec(spec);
  const gh = new GitHub({
    auth: authToken
  });

  return gh.rest.api.pullRequests.search({
    query: query,
    per_page: 100
  }).then(res => {
    return res.data.map(mapPRToUniformFormat);
  }).catch(() => []);
}

function buildQueryFromSpec(spec) {
  let query = 'is:pr is:open';
  if (spec.scope === 'author:@me') {
    query += ' author:@me';
  }
  if (spec.exclude_labels) {
    query += ` -label:${spec.exclude_labels.join(',')}`;
  }
  if (spec.require_state) {
    query += ` state:${spec.require_state}`;
  }
  if (spec.require_threads) {
    query += ` threads:${spec.require_threads}`;
  }
  if (spec.require_review) {
    query += ` review:${spec.require_review}`;
  }
  if (spec.require_ci) {
    query += ` CI_Status:${spec.require_ci || 'PASSING'}`;
  }
  if (spec.require_mergeable !== null) {
    query += ` mergeable:${spec.require_mergeable ? 'true' : 'false'}`;
  }
  return query;
}

function mapPRToUniformFormat(pr) {
  return {
    id: pr.number,
    title: pr.title,
    author: pr.user.login,
    labels: pr.labels.map(l => l.name),
    state: pr.state,
    review_requested: pr.review_requested,
    ci_status: pr.head_sha ? 'PASSING' : 'PENDING',
    mergeable: pr.mergeable,
    url: pr.html_url
  };
}
