from shop.pricing import apply_discount
from shop.cart import Cart
assert apply_discount(100, 10) == 90, apply_discount(100, 10)
assert apply_discount(80, 0) == 80
assert apply_discount(50, 100) == 0
cart = Cart(); cart.add_item("pen", 10, 2); cart.discount_percent = 50
assert cart.total() == 10, cart.total()
