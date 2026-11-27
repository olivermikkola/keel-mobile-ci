import unittest

from shop.cart import Cart


class CartTests(unittest.TestCase):
    def test_empty_cart_is_free(self):
        self.assertEqual(Cart().total(), 0)

    def test_quantity_must_be_positive(self):
        with self.assertRaises(ValueError):
            Cart().add_item("pen", 2.0, quantity=0)


if __name__ == "__main__":
    unittest.main()
