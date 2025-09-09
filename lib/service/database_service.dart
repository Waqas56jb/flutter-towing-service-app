import 'package:postgres_pool/postgres_pool.dart';
import '../models/mechanic_model.dart';

class DatabaseService {
  // Singleton pattern to ensure only one instance of DatabaseService
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  // Connection parameters from your Neon DB URL
  final String host =
      'ep-super-feather-a40n6zqs-pooler.us-east-1.aws.neon.tech';
  final int port = 5432;
  final String database = 'neondb';
  final String username = 'neondb_owner';
  final String password = 'npg_rW8D4kNJqYyT';
  final bool useSSL = true;

  PgPool? _pool;

  // Initialize the database connection pool
  Future<PgPool> _getPool() async {
    if (_pool == null) {
      _pool = PgPool(
        PgEndpoint(
          host: host,
          port: port,
          database: database,
          username: username,
          password: password,
          requireSsl: useSSL,
        ),
        settings: PgPoolSettings(),
      );
      // Create mechanics table if it doesn't exist
      await _createMechanicsTable();
    }
    return _pool!;
  }

  // Create mechanics table if it doesn't exist
  Future<void> _createMechanicsTable() async {
    final pool = await _getPool();
    await pool.execute('''
      CREATE TABLE IF NOT EXISTS mechanics (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        phone VARCHAR(20) NOT NULL,
        email VARCHAR(100) NOT NULL,
        address TEXT NOT NULL,
        years_of_experience INTEGER NOT NULL,
        specialty VARCHAR(100) NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');
  }

  // Insert a new mechanic into the database
  Future<int> insertMechanic(Mechanic mechanic) async {
    final pool = await _getPool();
    final results = await pool.query(
      '''
      INSERT INTO mechanics 
        (name, phone, email, address, years_of_experience, specialty, status)
      VALUES 
        (@name, @phone, @email, @address, @years_of_experience, @specialty, @status)
      RETURNING id
    ''',
      substitutionValues: {
        'name': mechanic.name,
        'phone': mechanic.phone,
        'email': mechanic.email,
        'address': mechanic.address,
        'years_of_experience': mechanic.yearsOfExperience,
        'specialty': mechanic.specialty,
        'status': mechanic.status,
      },
    );
    // Return the new mechanic ID
    return results[0][0] as int;
  }

  // Get all mechanics from the database
  Future<List<Mechanic>> getAllMechanics() async {
    final pool = await _getPool();
    final results = await pool.query('''
      SELECT * FROM mechanics ORDER BY created_at DESC
    ''');
    return results.map((row) {
      return Mechanic.fromMap({
        'id': row[0],
        'name': row[1],
        'phone': row[2],
        'email': row[3],
        'address': row[4],
        'years_of_experience': row[5],
        'specialty': row[6],
        'status': row[7],
        'created_at': row[8].toString(),
      });
    }).toList();
  }

  // Get a mechanic by ID
  Future<Mechanic?> getMechanicById(int id) async {
    final pool = await _getPool();
    final results = await pool.query(
      '''
      SELECT * FROM mechanics WHERE id = @id
    ''',
      substitutionValues: {'id': id},
    );
    if (results.isEmpty) {
      return null;
    }
    final row = results[0];
    return Mechanic.fromMap({
      'id': row[0],
      'name': row[1],
      'phone': row[2],
      'email': row[3],
      'address': row[4],
      'years_of_experience': row[5],
      'specialty': row[6],
      'status': row[7],
      'created_at': row[8].toString(),
    });
  }

  // Close the database connection pool
  Future<void> close() async {
    if (_pool != null) {
      await _pool!.close();
    }
  }
}
