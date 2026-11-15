from shop.pricing import format_price
from shop.cart import Cart
assert format_price(12.5) == "12.50 EUR", format_price(12.5)
assert format_price(12.5, "USD") == "12.50 USD" or format_price(12.5, currency="USD") == "12.50 USD"
assert format_price(3, currency="SEK") == "3.00 SEK"
cart = Cart(); cart.add_item("pen", 10, 2)
assert cart.summary().endswith("Total: 20.00 EUR"), cart.summary()
