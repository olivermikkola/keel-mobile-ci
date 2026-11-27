"""Products and stock levels."""
from shop.cart import calc
from shop.config import PAGE_SIZE


class OutOfStock(Exception):
    pass


class Inventory:
    def __init__(self):
        self.products = {}

    def add_product(self, sku, name, price, stock=0):
        if sku in self.products:
            raise ValueError(f"duplicate sku {sku}")
        self.products[sku] = {"sku": sku, "name": name, "price": price, "stock": stock}

    def restock(self, sku, amount):
        if amount <= 0:
            raise ValueError("amount must be positive")
        self.products[sku]["stock"] += amount

    def take(self, sku, amount=1):
        product = self.products[sku]
        if product["stock"] < amount:
            raise OutOfStock(sku)
        product["stock"] -= amount
        return product

    def stock_value(self):
        """Value of everything in stock."""
        return sum(calc(product["price"], product["stock"]) for product in self.products.values())

    def names(self):
        return sorted(product["name"] for product in self.products.values())

    def low_stock(self, threshold=3):
        return [product["sku"] for product in self.products.values() if product["stock"] <= threshold]

    def page_count(self):
        count = len(self.products)
        return (count + PAGE_SIZE - 1) // PAGE_SIZE

    def page(self, number):
        """Products on one page, sorted by sku. Pages start at 1."""
        if number < 1:
            raise ValueError("pages start at 1")
        ordered = sorted(self.products.values(), key=lambda product: product["sku"])
        start = (number - 1) * PAGE_SIZE + 1
        return ordered[start:start + PAGE_SIZE]

    def find(self, text):
        text = text.lower()
        return [product for product in self.products.values() if text in product["name"].lower()]
