# data-lake-platform Tiltfile
# Inner dev loop — assumes Terraform has bootstrapped Kind + ArgoCD (run `task up`)

print("""
========================================
  data-lake-platform: Dev Loop
  Tilt watches -> ArgoCD deploys
========================================
""")

# ==========================================================================
# File Watchers (ArgoCD syncs on commit, Tilt watches for awareness)
# ==========================================================================

watch_file('strimzi/')
watch_file('sample-postgres/')
watch_file('appset-management.yaml')

# ==========================================================================
# Utility Resources
# ==========================================================================

local_resource(
    'argocd-password',
    cmd='echo "ArgoCD Admin Password:" && ' +
        "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && " +
        'echo "" && echo "ArgoCD UI: http://localhost:8080"',
    labels=['info'],
    auto_init=True,
    trigger_mode=TRIGGER_MODE_MANUAL,
)

local_resource(
    'sync-status',
    cmd='echo "=== ApplicationSets ===" && ' +
        'kubectl -n argocd get applicationsets 2>/dev/null && ' +
        'echo "" && echo "=== Applications ===" && ' +
        'kubectl -n argocd get applications 2>/dev/null && ' +
        'echo "" && echo "=== Strimzi Namespace ===" && ' +
        'kubectl -n strimzi get pods 2>/dev/null && ' +
        'echo "" && echo "=== Data Namespace ===" && ' +
        'kubectl -n data get pods 2>/dev/null',
    labels=['info'],
    auto_init=False,
    trigger_mode=TRIGGER_MODE_MANUAL,
)

local_resource(
    'kafka-connect-status',
    cmd='kubectl -n strimzi get kafkaconnects,kafkaconnectors 2>/dev/null || echo "No Kafka Connect resources"',
    labels=['kafka'],
    auto_init=False,
    trigger_mode=TRIGGER_MODE_MANUAL,
)

local_resource(
    'cleanup',
    cmd='kubectl delete pods --field-selector=status.phase=Failed --all-namespaces 2>/dev/null || true && ' +
        'echo "Cleaned up failed pods"',
    labels=['utils'],
    auto_init=False,
    trigger_mode=TRIGGER_MODE_MANUAL,
)
