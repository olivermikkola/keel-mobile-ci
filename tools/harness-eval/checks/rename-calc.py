import pathlib, re
import shop
from shop.cart import Cart, line_total
from shop.inventory import Inventory
assert line_total(3, 4) == 12
for path in pathlib.Path("shop").glob("*.py"):
    assert not re.search(r"\bcalc\b", path.read_text()), f"{path} still mentions calc"
cart = Cart(); cart.add_item("pen", 10, 2)
assert cart.total() == 20 and "pen x2" in cart.summary()
inv = Inventory(); inv.add_product("a", "pen", 2.0, 5)
assert inv.stock_value() == 10
