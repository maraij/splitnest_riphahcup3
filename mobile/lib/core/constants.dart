import 'package:flutter/material.dart';

/// Category → Material icon (no emoji anywhere in the app).
const Map<String, IconData> categoryIcons = {
  'Groceries': Icons.local_grocery_store,
  'Utilities': Icons.bolt,
  'Cleaning': Icons.cleaning_services,
  'Entertainment': Icons.movie,
  'Dining': Icons.restaurant,
  'Snacks': Icons.fastfood,
  'General': Icons.receipt_long,
};

const List<String> categories = [
  'Groceries',
  'Utilities',
  'Cleaning',
  'Entertainment',
  'Dining',
  'Snacks',
  'General',
];

/// Categories a per-category budget cap can be set on. 'Grocery'
/// maps to the Groceries category; Internet/Electricity match by
/// expense title (they are Utilities in the app); Dining/Snacks are
/// their own categories.
const List<String> capCategories = [
  'Grocery',
  'Cleaning',
  'Internet',
  'Electricity',
  'Dining',
  'Snacks',
];
