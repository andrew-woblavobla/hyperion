# frozen_string_literal: true

# Bench-only initializer. Production needs a secret_key_base; in real
# Rails this comes from Rails.application.credentials, which we deleted.
# A static key is fine here — these processes never hold real secrets
# and never face the public internet.
Rails.application.config.secret_key_base = 'bench-' + ('0' * 60)
