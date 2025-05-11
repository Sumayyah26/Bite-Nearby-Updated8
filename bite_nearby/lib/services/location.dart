import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:location/location.dart' as loc;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geocoding/geocoding.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:bite_nearby/services/Restaurant_service.dart';
import 'package:firebase_auth/firebase_auth.dart';

class NotificationTemplate {
  final String id;
  final String title;
  final String body;
  final String type;

  NotificationTemplate({
    required this.id,
    required this.title,
    required this.body,
    required this.type,
  });

  factory NotificationTemplate.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return NotificationTemplate(
      id: doc.id,
      title: data['title'] ?? 'Nearby Restaurant',
      body: data['body'] ?? 'Check out this place!',
      type: data['type'] ?? 'recommendation',
    );
  }
}

class LocationService {
  final loc.Location _location = loc.Location();
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  bool _isMonitoring = false;
  Timer? _monitoringTimer;

  static const AndroidNotificationDetails _androidNotificationDetails =
      AndroidNotificationDetails(
    'proximity_channel',
    'Proximity Alerts',
    importance: Importance.high,
    priority: Priority.high,
    enableVibration: true,
    playSound: true,
  );

  static const NotificationDetails _platformChannelSpecifics =
      NotificationDetails(android: _androidNotificationDetails);

  Future<Map<String, dynamic>> getCurrentLocation() async {
    try {
      bool serviceEnabled = await _location.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await _location.requestService();
        if (!serviceEnabled) {
          throw Exception("Location services are disabled.");
        }
      }

      loc.PermissionStatus permissionGranted = await _location.hasPermission();
      if (permissionGranted == loc.PermissionStatus.denied) {
        permissionGranted = await _location.requestPermission();
        if (permissionGranted != loc.PermissionStatus.granted) {
          throw Exception("Location permission denied.");
        }
      }

      final locationData = await _location.getLocation();
      final latitude = locationData.latitude ?? 0.0;
      final longitude = locationData.longitude ?? 0.0;

      final address = await getAddressFromCoordinates(latitude, longitude);
      print("Fetched User Location: $address");

      return {
        'geoPoint': GeoPoint(latitude, longitude),
        'address': address,
      };
    } catch (e) {
      print("Error getting location: $e");
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> getPopularItems(
      String restaurantId) async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('Restaurants')
          .doc(restaurantId)
          .collection('menu')
          .orderBy('rating', descending: true)
          .limit(3)
          .get();

      return snapshot.docs.map((doc) => doc.data()).toList();
    } catch (e) {
      print('Error fetching menu items: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>?> _getRecommendationFromAPI(
      String restaurantId) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        print('No user logged in');
        return null;
      }

      // Get user preferences (same as your menu page)
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

      print('Calling recommendation API for restaurant: $restaurantId');
      print('Allergies: $allergies');
      print('Preferences: $preferences');

      // Using the same API call format as your menu page
      final response = await http
          .post(
            Uri.parse('https://ZienabM-food.hf.space/recommend'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              "restaurant_id": restaurantId,
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
          // Get the first valid recommended item (similar to menu page logic)
          final recommendedItem =
              (data['recommended_items'] as List).firstWhere(
            (item) =>
                item['item_id'] != null &&
                item['item_id'].toString().isNotEmpty,
            orElse: () => null,
          );

          if (recommendedItem != null) {
            // Try to get Firestore details like in your menu page
            try {
              final doc = await FirebaseFirestore.instance
                  .collection('Restaurants')
                  .doc(restaurantId)
                  .collection('menu')
                  .doc(recommendedItem['item_id'])
                  .get();

              if (doc.exists) {
                final firestoreData = doc.data() as Map<String, dynamic>;
                return {
                  'name': firestoreData['Name'] ?? recommendedItem['name'],
                  'description': firestoreData['Description'] ??
                      recommendedItem['description'] ??
                      '',
                  'image_url': firestoreData['image_url'] ??
                      recommendedItem['image_url'],
                  'source': 'api',
                  'score': recommendedItem['similarity_score']?.toDouble(),
                };
              }
            } catch (e) {
              print('Error fetching Firestore details: $e');
            }

            // Fallback to API data if Firestore fetch fails
            return {
              'name': recommendedItem['name'] ?? 'Recommended dish',
              'description': recommendedItem['description'] ?? '',
              'image_url': recommendedItem['image_url'],
              'source': 'api',
              'score': recommendedItem['similarity_score']?.toDouble(),
            };
          }
        }
      }

      // If API fails, return null to trigger Firestore fallback
      return null;
    } catch (e) {
      print('Error in _getRecommendationFromAPI: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>> _getFallbackItem(String restaurantId) async {
    final popularItems = await getPopularItems(restaurantId);
    if (popularItems.isNotEmpty) {
      return {
        'name': popularItems.first['Name'] ?? 'Popular dish',
        'description': popularItems.first['Description'] ?? '',
        'image_url': popularItems.first['image_url'],
        'source': 'firestore',
      };
    }
    return {
      'name': 'Special dish',
      'description': '',
      'image_url': null,
      'source': 'fallback',
    };
  }

  Future<NotificationTemplate?> getRandomNotificationTemplate() async {
    try {
      final querySnapshot = await FirebaseFirestore.instance
          .collection('notification_templates')
          .get();

      if (querySnapshot.docs.isEmpty) return null;

      final randomIndex = Random().nextInt(querySnapshot.docs.length);
      return NotificationTemplate.fromFirestore(
          querySnapshot.docs[randomIndex]);
    } catch (e) {
      print("Error fetching templates: $e");
      return null;
    }
  }

  Future<void> showDynamicNotification(Map<String, dynamic> restaurant) async {
    try {
      print('Preparing notification for: ${restaurant['name']}');

      // 1. Try API first (using the improved method above)
      Map<String, dynamic>? recommendation;
      try {
        recommendation = await _getRecommendationFromAPI(restaurant['id']);
        if (recommendation != null &&
            recommendation['name']?.isNotEmpty == true) {
          print('API recommendation: ${recommendation['name']}');
        }
      } catch (apiError) {
        print('API error: $apiError');
      }

      // 2. Fallback to Firestore if API fails (similar to your menu page fallback)
      if (recommendation == null) {
        print('Falling back to Firestore top items');
        final popularItems = await getPopularItems(restaurant['id']);
        if (popularItems.isNotEmpty) {
          recommendation = {
            'name': popularItems.first['Name'] ?? 'Special dish',
            'description': popularItems.first['Description'] ?? '',
            'image_url': popularItems.first['image_url'],
            'source': 'firestore',
          };
        } else {
          recommendation = {
            'name': 'Special dish',
            'description': '',
            'image_url': null,
            'source': 'fallback',
          };
        }
      }

      // 3. Get notification template
      final template = await getRandomNotificationTemplate();
      final restaurantName =
          restaurant['name']?.toString().trim() ?? 'a nearby restaurant';
      final itemName =
          recommendation['name']?.toString().trim() ?? 'a special dish';

      // 4. Create notification content with score if available
      final score = recommendation['score'] != null
          ? ' (${(recommendation['score']! * 100).toStringAsFixed(0)}% match)'
          : '';

      final title = (template?.title ?? 'Try {item_name} at {restaurant_name}')
          .replaceAll('{restaurant_name}', restaurantName)
          .replaceAll('{item_name}', itemName);

      final body = (template?.body ??
              'We think you\'ll love {item_name}$score at {restaurant_name}!')
          .replaceAll('{restaurant_name}', restaurantName)
          .replaceAll('{item_name}', itemName);

      // 5. Show notification (with image if available)
      if (recommendation['image_url'] != null) {
        try {
          final largeIcon = await _downloadImage(recommendation['image_url']);
          await _notificationsPlugin.show(
            restaurant['id'].hashCode,
            title,
            body,
            NotificationDetails(
              android: AndroidNotificationDetails(
                'proximity_channel',
                'Proximity Alerts',
                importance: Importance.high,
                priority: Priority.high,
                largeIcon: largeIcon,
                styleInformation: BigPictureStyleInformation(
                  largeIcon,
                  contentTitle: title,
                  summaryText: body,
                ),
              ),
            ),
            payload: 'restaurant:${restaurant['id']}',
          );
          return;
        } catch (e) {
          print('Error showing image notification: $e');
        }
      }

      // Fallback to simple notification
      await _notificationsPlugin.show(
        restaurant['id'].hashCode,
        title,
        body,
        _platformChannelSpecifics,
        payload: 'restaurant:${restaurant['id']}',
      );
    } catch (e) {
      print('Error in showDynamicNotification: $e');
      // Ultra-fallback notification
      await _notificationsPlugin.show(
        Random().nextInt(100000),
        'New recommendation nearby!',
        'Check out ${restaurant['name'] ?? 'this restaurant'}',
        _platformChannelSpecifics,
      );
    }
  }

  Future<ByteArrayAndroidBitmap> _downloadImage(String url) async {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      return ByteArrayAndroidBitmap(response.bodyBytes);
    }
    throw Exception('Failed to download image');
  }

  Future<void> startProximityMonitoring() async {
    if (_isMonitoring) return;
    _isMonitoring = true;

    const interval = Duration(minutes: 1);
    _monitoringTimer = Timer.periodic(interval, (timer) async {
      try {
        print("Checking proximity...");
        final locationData = await getCurrentLocation();
        final restaurants = await RestaurantService().getSortedRestaurants();

        if (restaurants.isNotEmpty) {
          final nearest = restaurants.first;
          final distanceKm = nearest['distance'] / 1000;
          print("Nearest restaurant: ${nearest['name']} ($distanceKm km away)");

          if (distanceKm <= 15) {
            await showDynamicNotification(nearest);
          }
        }
      } catch (e) {
        print('Proximity monitoring error: $e');
      }
    });
  }

  Future<String> getAddressFromCoordinates(double lat, double lng) async {
    try {
      final placemarks = await placemarkFromCoordinates(lat, lng);
      if (placemarks.isNotEmpty) {
        final place = placemarks[0];
        return "${place.street}, ${place.locality}, ${place.country}";
      }
      return "Unknown location";
    } catch (e) {
      print("Error fetching address: $e");
      return "Unknown location";
    }
  }

  void stopProximityMonitoring() {
    _monitoringTimer?.cancel();
    _isMonitoring = false;
  }

  void dispose() {
    stopProximityMonitoring();
  }
}
