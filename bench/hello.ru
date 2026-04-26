# frozen_string_literal: true

run ->(_env) { [200, { 'content-type' => 'text/plain' }, ['hello']] }
