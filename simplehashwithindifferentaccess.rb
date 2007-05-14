class Hash
  alias :orig_square :[]
  def [](key)
    if key.is_a?(Symbol) && has_key?(key.id2name) && !has_key?(key)
      return self[key.id2name]
    end
    orig_square(key)
  end
end
