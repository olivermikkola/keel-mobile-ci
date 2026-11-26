from shop.coupons import is_valid
assert is_valid("KEEL-1234") is True
assert is_valid("KEEL-12345") is False
assert is_valid("KEEL-123") is False
assert is_valid("SALE-1234") is False
assert is_valid("") is False
