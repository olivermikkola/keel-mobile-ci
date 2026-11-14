from shop.pricing import total_with_tax, apply_discount
from shop.cart import Cart
cart = Cart(); cart.add_item("pen", 10, 2); cart.add_item("ink", 5, 1)
assert abs(total_with_tax(cart) - 25 * 1.24) < 1e-9, total_with_tax(cart)
import shop.config as config
config_source = open("shop/pricing.py").read()
assert "TAX_RATE" in config_source, "must use TAX_RATE from the config"
assert apply_discount(100, 0) == 100
