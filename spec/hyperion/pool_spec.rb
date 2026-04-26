# frozen_string_literal: true

RSpec.describe Hyperion::Pool do
  it 'reuses objects across acquire/release cycles' do
    counter = 0
    pool = described_class.new(
      max_size: 4,
      factory: lambda {
        counter += 1
        "obj#{counter}"
      }
    )

    a = pool.acquire
    b = pool.acquire
    expect(a).to eq('obj1')
    expect(b).to eq('obj2')

    pool.release(a)
    expect(pool.acquire).to eq('obj1') # reused
  end

  it 'resets objects on acquire' do
    pool = described_class.new(
      max_size: 4,
      factory: -> { String.new },
      reset: ->(s) { s.clear }
    )

    a = pool.acquire
    a << 'data'
    pool.release(a)

    b = pool.acquire
    expect(b.equal?(a)).to be(true) # same object
    expect(b).to eq('') # but reset
  end

  it 'caps free-list at max_size' do
    pool = described_class.new(max_size: 2, factory: -> { Object.new })

    objs = Array.new(5) { pool.acquire }
    objs.each { |o| pool.release(o) }

    expect(pool.size).to eq(2)
  end
end
