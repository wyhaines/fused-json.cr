require "./spec_helper"

module FusedJSON
  describe KeyCache do
    it "keeps an owned string on a miss and copies borrowed bytes on a miss" do
      cache = KeyCache.new
      owned = "decoded-key"
      cache.get(owned).same?(owned).should be_true
      cache.get(owned.to_unsafe, owned.bytesize).same?(owned).should be_true

      buffer = "other-key".to_slice.dup
      cached = cache.get(buffer.to_unsafe, buffer.size)
      buffer.fill(0_u8)
      cached.should eq("other-key")
      cache.get("other-key").same?(cached).should be_true
    end
  end
end
