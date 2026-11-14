import shop.config as config
from shop.inventory import Inventory
assert config.PAGE_SIZE == 20, config.PAGE_SIZE
readme = open("README.md").read()
assert "20 items" in readme and "10 items" not in readme, "README must say 20 items"
inv = Inventory()
for i in range(25): inv.add_product(f"sku{i:02d}", f"item {i}", 1.0, 1)
assert inv.page_count() == 2
