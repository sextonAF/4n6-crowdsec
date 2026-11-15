/** A removable, long-lived CrowdSec ban distinct from automated temporary decisions.
 * CrowdSec requires an expiry; ten years is deliberately long, not infinite.
 * The reason marker is used by the Banned IPs page and its dashboard count.
 */
export const MANAGED_BAN_REASON = 'permanent-ban';
export const MANAGED_BAN_DURATION = '87600h'; // ~10 years
export const MANAGED_BAN_QUERY = 'type:ban AND status:active AND origin:cscli AND scenario:permanent-ban';
