from shop.inventory import Inventory
inv = Inventory()
for i in range(25): inv.add_product(f"sku{i:02d}", f"item {i}", 1.0, 1)
first, second, third = inv.page(1), inv.page(2), inv.page(3)
assert [p["sku"] for p in first] == [f"sku{i:02d}" for i in range(10)], first
assert [p["sku"] for p in second] == [f"sku{i:02d}" for i in range(10, 20)], second
assert [p["sku"] for p in third] == [f"sku{i:02d}" for i in range(20, 25)], third
assert inv.page_count() == 3
