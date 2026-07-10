const VERSION = 'disabled-by-agent-pullpoint-v3';

export function startOnvifLegacyFallbackCollector() {
  console.log('[onvif-events:legacy-fallback] disabled', {
    version: VERSION,
    reason: 'replaced by the single node-agent PullPoint collector'
  });
}
