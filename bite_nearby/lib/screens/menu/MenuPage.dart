import 'package:bite_nearby/screens/menu/CartModel.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import 'package:bite_nearby/Coolors.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'CartService.dart';
import 'CartProvider.dart';
import 'CartPage.dart';

class MenuPage extends StatefulWidget {
  final String restaurantId;
  final String restaurantName;

  const MenuPage(
      {super.key, required this.restaurantId, this.restaurantName = ''});

  @override
  _MenuPageState createState() => _MenuPageState();
}

class _MenuPageState extends State<MenuPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ScrollController _scrollController = ScrollController();
  final List<String> allCategories = [
    'Your Menu',
    'Appetizers',
    'Main Course',
    'Side Dish',
    'Drinks',
    'Dessert'
  ];
  List<String> availableCategories = [];
  final Map<String, GlobalKey> _categoryKeys = {};
  List<Map<String, dynamic>> personalizedMenu = [];
  String? userId;
  final CartService _cartService = CartService();
  int _cartItemCount = 0;
  bool _isLoadingPersonalized = true;

  @override
  void initState() {
    super.initState();
    _fetchAvailableCategories();
    _loadCartCount();
    _fetchPersonalizedMenu();
  }

  void _loadCartCount() async {
    final items = await _cartService.getCartItems();
    if (mounted) {
      setState(() {
        _cartItemCount = items.length;
      });
    }
  }

  Future<void> _fetchPersonalizedMenu() async {
    try {
      setState(() => _isLoadingPersonalized = true);
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        print('No user logged in');
        return;
      }

      // Get user preferences
      final userSnapshot = await FirebaseFirestore.instance
          .collection('Users')
          .doc(user.uid)
          .get();

      final allergies = List<String>.from(userSnapshot
              .get('allergens')
              ?.map((a) => a.toString().toLowerCase()) ??
          []);
      final preferences = List<String>.from(userSnapshot
              .get('preferredIngredients')
              ?.map((p) => p.toString().toLowerCase()) ??
          []);

      print(
          'Calling personalized menu API for restaurant: ${widget.restaurantId}');
      print('Allergies: $allergies');
      print('Preferences: $preferences');

      // Call API for personalized recommendations
      final response = await http
          .post(
            Uri.parse('https://ZienabM-food.hf.space/recommend'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              "restaurant_id": widget.restaurantId,
              "allergies": allergies,
              "preferences": preferences,
              "item_id": "",
              "return_full_items": true,
            }),
          )
          .timeout(Duration(seconds: 30));

      print('API Response: ${response.statusCode} - ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['recommended_items'] != null &&
            data['recommended_items'].isNotEmpty) {
          // Process API recommendations
          final recommendedItems =
              List<Map<String, dynamic>>.from(data['recommended_items'])
                  .where((item) =>
                      item['item_id'] != null &&
                      item['item_id']
                          .toString()
                          .isNotEmpty) // Filter out items with empty IDs
                  .toList();

          // Get additional details from Firestore for each recommended item
          final detailedItems = <Map<String, dynamic>>[];

          for (final item in recommendedItems) {
            try {
              final doc = await FirebaseFirestore.instance
                  .collection('Restaurants')
                  .doc(widget.restaurantId)
                  .collection('menu')
                  .doc(item['item_id'])
                  .get();

              if (doc.exists) {
                final firestoreData = doc.data() as Map<String, dynamic>;
                detailedItems.add({
                  ...firestoreData,
                  'id': doc.id,
                  'score': item['similarity_score']?.toDouble(),
                  // Use API data only if Firestore data is missing
                  'image_url': firestoreData['image_url'] ?? item['image_url'],
                  'Name': firestoreData['Name'] ?? item['name'],
                  'Description':
                      firestoreData['Description'] ?? item['description'],
                  'Price': firestoreData['Price'] ?? item['price'],
                });
              } else {
                // If Firestore doc doesn't exist, use API data with required fields
                detailedItems.add({
                  'id': item['item_id'],
                  'Name': item['name']?.isNotEmpty == true
                      ? item['name']
                      : 'Recommended Dish',
                  'Description': item['description']?.isNotEmpty == true
                      ? item['description']
                      : '',
                  'Price': item['price'] ?? 0.0,
                  'image_url': item['image_url'],
                  'score': item['similarity_score']?.toDouble(),
                });
              }
            } catch (e) {
              print('Error processing item ${item['item_id']}: $e');
            }
          }

          if (mounted) {
            setState(() {
              personalizedMenu = detailedItems;
              _isLoadingPersonalized = false;
            });
          }
          return;
        }
      }

      // Fallback to top-rated items if API fails or returns no valid items
      await _getFallbackTopRatedItems();
    } catch (e) {
      print('Error in _fetchPersonalizedMenu: $e');
      // Fallback to top-rated items
      await _getFallbackTopRatedItems();
    } finally {
      if (mounted) {
        setState(() => _isLoadingPersonalized = false);
      }
    }
  }

  Future<void> _getFallbackTopRatedItems() async {
    try {
      print('Using fallback: fetching top-rated items');
      final QuerySnapshot menuItems = await FirebaseFirestore.instance
          .collection('Restaurants')
          .doc(widget.restaurantId)
          .collection('menu')
          .orderBy('rating', descending: true)
          .limit(3)
          .get();

      final items = menuItems.docs.map((doc) {
        return {
          ...doc.data() as Map<String, dynamic>,
          'id': doc.id,
        };
      }).toList();

      if (mounted) {
        setState(() {
          personalizedMenu = items;
        });
      }
    } catch (e) {
      print('Error in fallback: $e');
      if (mounted) {
        setState(() {
          personalizedMenu = [];
        });
      }
    }
  }

  Future<void> _fetchAvailableCategories() async {
    final menuItems = await FirebaseFirestore.instance
        .collection('Restaurants')
        .doc(widget.restaurantId)
        .collection('menu')
        .get();

    final groupedItems = _groupByCategory(menuItems.docs);

    setState(() {
      availableCategories = allCategories
          .where((category) =>
              category == 'Your Menu' || groupedItems.containsKey(category))
          .toList();

      for (String category in availableCategories) {
        _categoryKeys[category] = GlobalKey();
      }

      _tabController =
          TabController(length: availableCategories.length, vsync: this);

      _scrollController.addListener(() {
        for (int i = 0; i < availableCategories.length; i++) {
          final category = availableCategories[i];
          final context = _categoryKeys[category]?.currentContext;
          if (context != null) {
            final box = context.findRenderObject() as RenderBox;
            final position = box.localToGlobal(Offset.zero);
            if (position.dy >= 0 && position.dy < 200) {
              _tabController.animateTo(i);
              break;
            }
          }
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: null,
      backgroundColor: Coolors.ivoryCream,
      body: Column(
        children: [
          // Custom header matching other screens
          Container(
            margin: EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Coolors.charcoalBlack,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.5),
                  blurRadius: 8,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: Text(
                    widget.restaurantName.isNotEmpty
                        ? widget.restaurantName
                        : 'Menu',
                    style: TextStyle(
                      fontFamily: 'Times New Roman',
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                if (availableCategories.isNotEmpty)
                  Container(
                    margin: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Coolors.charcoalBlack,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: TabBar(
                      controller: _tabController,
                      isScrollable: true,
                      tabs: availableCategories
                          .map((category) => Tab(text: category))
                          .toList(),
                      indicator: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: Coolors.gold,
                      ),
                      labelColor: Colors.white,
                      unselectedLabelColor: Colors.white70,
                      onTap: (index) {
                        final category = availableCategories[index];
                        final context = _categoryKeys[category]?.currentContext;
                        if (context != null) {
                          Scrollable.ensureVisible(
                            context,
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                          );
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: availableCategories.isNotEmpty
                ? StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('Restaurants')
                        .doc(widget.restaurantId)
                        .collection('menu')
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                        return const Center(
                            child: Text('No menu items found.'));
                      }

                      final menuItems = snapshot.data!.docs;
                      final categoriesMap = _groupByCategory(menuItems);

                      return ListView(
                        controller: _scrollController,
                        children: availableCategories.map((category) {
                          return _buildCategorySection(
                            category,
                            category == 'Your Menu'
                                ? (_isLoadingPersonalized
                                    ? []
                                    : personalizedMenu)
                                : categoriesMap[category] ?? [],
                            isLoading: category == 'Your Menu' &&
                                _isLoadingPersonalized,
                          );
                        }).toList(),
                      );
                    },
                  )
                : const Center(child: CircularProgressIndicator()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => CartPage(
                restaurantId: widget.restaurantId,
                restaurantName: widget.restaurantName,
              ),
            ),
          );
        },
        backgroundColor: Coolors.gold,
        child: Consumer<CartProvider>(
          builder: (context, cart, child) {
            final count =
                cart.getItemsForRestaurant(widget.restaurantId).length;
            return Stack(
              children: [
                const Icon(Icons.shopping_cart, color: Colors.white),
                if (count > 0)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Coolors.wineRed,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 16,
                        minHeight: 16,
                      ),
                      child: Text(
                        '$count',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildCategorySection(String category, List<dynamic> items,
      {bool isLoading = false}) {
    return Column(
      key: _categoryKeys[category],
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            category,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ),
        if (isLoading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (items.isEmpty && category == 'Your Menu')
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('No personalized recommendations available'),
          )
        else
          ...items.map((item) {
            final data = item is DocumentSnapshot
                ? item.data() as Map<String, dynamic>
                : item;
            return _buildMenuItemCard(data);
          }),
      ],
    );
  }

  Map<String, IconData> allergenIcons = {
    'Peanuts': Icons.ac_unit,
    'Tree nuts': Icons.nature,
    'Dairy': Icons.local_drink_outlined,
    'Eggs': Icons.egg_alt,
    'Shellfish': Icons.set_meal,
    'Wheat': Icons.spa,
    'Soy': Icons.grain,
  };

  Widget _buildMenuItemCard(Map<String, dynamic> data) {
    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => MenuItemDetailsPage(
                itemData: data,
                onAddToCart: () async {
                  try {
                    final cart =
                        Provider.of<CartProvider>(context, listen: false);
                    final newItem = CartItem(
                      id: data['id'] ?? DateTime.now().toString(),
                      title: data['Name'] ?? 'Unknown',
                      price: double.parse(data['Price'].toString()),
                      restaurantId: widget.restaurantId,
                      imageUrl: data['image_url'],
                    );
                    cart.addItem(newItem);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Added to cart!')),
                    );
                  } catch (e) {
                    print('Error adding to cart: $e');
                  }
                }),
          ),
        );
      },
      child: Card(
        color: const Color.fromARGB(255, 255, 255, 255),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            if (data['image_url'] != null)
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  image: DecorationImage(
                    image: NetworkImage(data['image_url']),
                    fit: BoxFit.cover,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
              )
            else
              Container(
                width: 100,
                height: 100,
                color: Colors.grey[300],
                child: const Center(
                  child: Icon(Icons.image_not_supported, size: 40),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data['Name'] ?? 'Unnamed Item',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Rating display
                    if (data['rating'] != null)
                      Row(
                        children: [
                          Icon(Icons.star, size: 16, color: Coolors.gold),
                          SizedBox(width: 4),
                          Text(
                            data['rating'].toStringAsFixed(1),
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[700],
                            ),
                          ),
                          SizedBox(width: 8),
                        ],
                      ),
                    if (data['score'] != null)
                      Text(
                        "Score: ${data['score'].toStringAsFixed(2)}",
                        style: TextStyle(fontSize: 14, color: Colors.grey[700]),
                      ),
                    const SizedBox(height: 4),
                    if (data['Price'] != null)
                      Text(
                        '${data['Price']} SR',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Coolors.oliveGreen,
                        ),
                      ),
                    const SizedBox(height: 4),
                    if (data.containsKey('Allergens') &&
                        data['Allergens'] is List &&
                        (data['Allergens'] as List).isNotEmpty)
                      Row(
                        children: (data['Allergens'] as List<dynamic>)
                            .where((allergen) =>
                                allergen != null &&
                                allergenIcons.containsKey(allergen.trim()))
                            .map((allergen) => Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Icon(
                                    allergenIcons[allergen.trim()],
                                    size: 20,
                                    color: const Color.fromARGB(255, 0, 0, 0),
                                  ),
                                ))
                            .toList(),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Map<String, List<DocumentSnapshot>> _groupByCategory(
      List<DocumentSnapshot> menuItems) {
    final Map<String, List<DocumentSnapshot>> grouped = {};
    for (var item in menuItems) {
      final data = item.data() as Map<String, dynamic>;
      final category = data['Category'] ?? 'Uncategorized';
      if (!grouped.containsKey(category)) {
        grouped[category] = [];
      }
      grouped[category]!.add(item);
    }
    return grouped;
  }
}

class MenuItemDetailsPage extends StatelessWidget {
  final Map<String, dynamic> itemData;
  final VoidCallback? onAddToCart;

  const MenuItemDetailsPage(
      {super.key, required this.itemData, this.onAddToCart});

  Widget _buildHeader() {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Coolors.charcoalBlack,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Center(
        child: Text(
          itemData['Name'] ?? 'Menu Item',
          style: TextStyle(
            fontFamily: 'Times New Roman',
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: null,
      backgroundColor: Colors.white,
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (itemData['image_url'] != null)
                    Container(
                      width: double.infinity,
                      height: 300,
                      decoration: BoxDecoration(
                        image: DecorationImage(
                          image: NetworkImage(itemData['image_url']),
                          fit: BoxFit.cover,
                        ),
                      ),
                    )
                  else
                    Container(
                      width: double.infinity,
                      height: 300,
                      color: Colors.grey[300],
                      child: Center(
                        child: Icon(Icons.image_not_supported, size: 100),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Rating display
                        if (itemData['rating'] != null)
                          Row(
                            children: [
                              Icon(Icons.star, size: 24, color: Coolors.gold),
                              SizedBox(width: 8),
                              Text(
                                itemData['rating'].toStringAsFixed(1),
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey[800],
                                ),
                              ),
                            ],
                          ),
                        SizedBox(height: 16),
                        if (itemData['Description'] != null) ...[
                          Text(
                            itemData['Description'],
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey[700],
                            ),
                          ),
                          SizedBox(height: 16),
                        ],
                        if (itemData['Price'] != null)
                          Text(
                            'Price: ${itemData['Price']} SR',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Coolors.oliveGreen,
                            ),
                          ),
                        if (itemData['Ingredients'] != null &&
                            itemData['Ingredients'] is List) ...[
                          SizedBox(height: 16),
                          Text(
                            'Ingredients:',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          ...List<String>.from(itemData['Ingredients'])
                              .map((ingredient) => Padding(
                                    padding: EdgeInsets.only(top: 4),
                                    child: Text('- $ingredient'),
                                  )),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        margin: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: ElevatedButton(
          onPressed: () {
            if (onAddToCart != null) {
              onAddToCart!();
              Navigator.pop(context);
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Coolors.gold,
            padding: EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Text(
            'Add to Cart',
            style: TextStyle(
              fontSize: 18,
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
