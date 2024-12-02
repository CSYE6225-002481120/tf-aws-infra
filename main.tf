// server.js

import express from 'express';
import { Sequelize, DataTypes } from 'sequelize';
import dotenv from 'dotenv';
import basicAuth from 'basic-auth';
import moment from 'moment-timezone';
import bcrypt from 'bcrypt';
import AWS from 'aws-sdk';
import multer from 'multer';
import winston from 'winston';
import StatsD from 'node-statsd';
import crypto from 'crypto';

dotenv.config();

const app = express();
app.use(express.json());
app.use((req, res, next) => {
  res.set('Cache-Control', 'no-cache, no-store, must-revalidate');
  res.set('Pragma', 'no-cache');
  res.set('X-Content-Type-Options', 'nosniff');
  next();
});
app.disable('x-powered-by');

// Configure Winston logger
const logger = winston.createLogger({
  level: 'info', // Adjust the level as needed (error, warn, info, verbose, debug, silly)
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.json()
  ),
  transports: [
    // Log to a file that CloudWatch Agent will monitor
    new winston.transports.File({ filename: '/home/csye6225/app/app.log' }),
  ],
});

// Add console logging in non-production environments
if (process.env.NODE_ENV !== 'production') {
  logger.add(
    new winston.transports.Console({
      format: winston.format.simple(),
    })
  );
}

// Initialize StatsD client
const statsdClient = new StatsD({
  host: 'localhost', // StatsD server address
  port: 8125,        // Default StatsD port
});

// Initialize an object to keep track of counts for each endpoint
const apiCallCounts = {};

// Middleware to measure API request duration and count
app.use((req, res, next) => {
  const startTime = process.hrtime();

  // Define metric names based on the endpoint and method
  let countMetricName = '';
  let responseTimeMetricName = '';

  // Map endpoints and methods to metric names
  if (req.method === 'GET' && req.path === '/healthz') {
    countMetricName = 'method.healthz_count';
    responseTimeMetricName = 'method.healthz_responsetime';
  } else if (req.method === 'POST' && req.path === '/v2/user') {
    countMetricName = 'POST.Create_count';
    responseTimeMetricName = 'POST.Create_responsetime';
  } else if (req.method === 'GET' && req.path === '/v1/user/self') {
    countMetricName = 'GET.Fetchuser_count';
    responseTimeMetricName = 'GET.Fetchuser_responsetime';
  } else if (req.method === 'PUT' && req.path === '/v1/user/self') {
    countMetricName = 'PUT.Updateuser_count';
    responseTimeMetricName = 'PUT.Updateuser_response';
  } else if (req.method === 'POST' && req.path === '/v1/user/self/pic') {
    countMetricName = 'POST.addpic_count';
    responseTimeMetricName = 'POST.addpic_responsetime';
  } else if (req.method === 'DELETE' && req.path === '/v1/user/self/pic') {
    countMetricName = 'DELETE.removepic_count';
    responseTimeMetricName = 'DELETE.removepic_responsetime';
  } else {
    // For any other endpoints, you can assign default metric names or skip
    next();
    return;
  }

  // Increment the counter in StatsD
  statsdClient.increment(countMetricName);

  // Increment the in-memory counter
  if (!apiCallCounts[countMetricName]) {
    apiCallCounts[countMetricName] = 0;
  }
  apiCallCounts[countMetricName] += 1;

  res.on('finish', () => {
    const diff = process.hrtime(startTime);
    const durationInMs = (diff[0] * 1e9 + diff[1]) / 1e6; // Convert to milliseconds

    // Send timing metric to StatsD
    statsdClient.timing(responseTimeMetricName, durationInMs);

    // Log the current count
    console.log(`Endpoint: ${req.method} ${req.path}`);
    console.log(`Metric: ${countMetricName}`);
    console.log(`Total calls: ${apiCallCounts[countMetricName]}`);
  });

  next();
});

// Database connection
const sequelize = new Sequelize(
  process.env.DB_name,
  process.env.DB_username,
  process.env.DB_password,
  {
    host: process.env.DB_host,
    dialect: 'mysql',
  }
);

// User model
const User = sequelize.define(
  'User',
  {
    id: {
      type: DataTypes.UUID,
      defaultValue: DataTypes.UUIDV4,
      allowNull: false,
      unique: true,
      primaryKey: true,
    },

    email: {
      type: DataTypes.STRING,
      allowNull: true,
      unique: true,
    },
    password: {
      type: DataTypes.STRING,
      allowNull: true,
    },
    firstName: {
      type: DataTypes.STRING,
      allowNull: true,
    },
    lastName: {
      type: DataTypes.STRING,
      allowNull: true,
    },
    account_created: {
      type: DataTypes.DATE,
      defaultValue: DataTypes.NOW,
    },
    account_updated: {
      type: DataTypes.DATE,
      defaultValue: DataTypes.NOW,
    },
    // Fields for image storage
    file_name: {
      type: DataTypes.STRING,
      allowNull: true,
    },
    url: {
      type: DataTypes.STRING,
      allowNull: true,
    },
    verificationToken: {
      type: DataTypes.STRING,
      allowNull: true, // Can be null once the user is verified
    },
    tokenExpiration: {
      type: DataTypes.DATE,
      allowNull: true, // Can be null once the user is verified
    },
    isVerified: {
      type: DataTypes.BOOLEAN,
      defaultValue: false, // User is not verified by default
    },      
  },
  {
    timestamps: false,
  }
);

// Authentication middleware
const authenticate = async (req, res, next) => {
  try {
    const authHeader = req.get('Authorization');
    let email, password;

    if (!authHeader) {
      logger.warn('Unauthorized access attempt: Missing Authorization header');
      return res.status(401).end();
    }

    if (authHeader.startsWith('Basic ')) {
      // Standard Basic Auth
      const base64Credentials = authHeader.split(' ')[1];
      const credentials = Buffer.from(base64Credentials, 'base64').toString('ascii');
      [email, password] = credentials.split(':');
    } else {
      // Non-standard: Authorization header contains email:password directly
      [email, password] = authHeader.split(':');
    }

    if (!email || !password) {
      logger.warn('Invalid credentials format');
      return res.status(401).json({ message: 'Invalid credentials format' });
    }

    // Start timing the database operation
    const dbStartTime = process.hrtime();

    const user = await User.findOne({ where: { email } });
    
    // Measure DB operation duration
    const dbDiff = process.hrtime(dbStartTime);
    const dbDurationInMs = (dbDiff[0] * 1e9 + dbDiff[1]) / 1e6;

    // Send timing metric to StatsD
    statsdClient.timing('GET.Fetchuser_database_time', dbDurationInMs);

    if (!user) {
      logger.warn('User not found', { email });
      return res.status(404).json({ message: 'User not found' });
    }
    if(user.isVerified == 0){
      return res.status(403).json({ message: 'User not verified' });
    }

    const passwordMatch = await bcrypt.compare(password, user.password);
    if (!passwordMatch) {
      logger.warn('Invalid password attempt', { email });
      return res.status(401).json({ message: 'Invalid credentials' });
    }

    req.user = user;
    next();
  } catch (error) {
    logger.error('Error in authentication middleware', { error: error.message });
    return res.status(500).end();
  }
};

// Health check endpoint
app.all('/healthz', (req, res, next) => {
  if (req.method !== 'GET') {
    return res.status(405).end();
  }
  next();
});


app.get('/healthz', async (req, res) => {
  const dbStartTime = process.hrtime();
  try {
    if (Object.keys(req.query).length > 0) {
      logger.warn('Query parameters not allowed in health check');
      return res.status(400).end();
    }
    if (req.get('Content-Length') && parseInt(req.get('Content-Length')) > 0) {
      logger.warn('Content-Length not allowed in health check');
      return res.status(400).end();
    }

    // Start timing the database authentication
    const dbStartTime = process.hrtime();

    await sequelize.authenticate();

    // Measure DB authentication duration
    const dbDiff = process.hrtime(dbStartTime);
    const dbDurationInMs = (dbDiff[0] * 1e9 + dbDiff[1]) / 1e6;

    // Send timing metric for DB authentication
    statsdClient.timing('method.healthz_database_time', dbDurationInMs);

    logger.info('Health check passed');
    return res.status(200).end();
  } catch (error) {
    logger.error('Health check failed', { error: error.message });
    return res.status(503).end();
  }
});


// User routes
app.all('/v1/user/self', (req, res, next) => {
  if (req.method === 'HEAD' || req.method === 'OPTIONS' || req.method === 'PATCH') {
    return res.status(405).end();
  }
  next();
});

app.all('/v1/user/self/pic', (req, res, next) => {
  if (req.method === 'HEAD' || req.method === 'OPTIONS' || req.method === 'PATCH' || req.method === 'GET' || req.method === 'PUT') {
    return res.status(405).end();
  }
  next();
});



app.post('/v1/user', async (req, res) => {
  // Start timing the overall request
  const requestStartTime = process.hrtime();

  try {
    // Check if request body is empty
    if (!req.body || Object.keys(req.body).length === 0) {
      logger.warn('Empty request body in user creation');
      return res.status(422).send('Request body is empty');
    }

    const { email, password, firstName, lastName } = req.body;
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

    // Validate user input
    if (!firstName || firstName.trim() === '') {
      logger.warn('Firstname cannot be empty');
      return res.status(422).json({ message: 'Firstname cannot be empty' });
    }
    if (!lastName || lastName.trim() === '') {
      logger.warn('Lastname cannot be empty');
      return res.status(422).json({ message: 'Lastname cannot be empty' });
    }
    if (!password || password.trim() === '' || password.includes(' ') || password.length < 8) {
      logger.warn('Invalid password');
      return res.status(422).json({ message: 'Password should be at least 8 characters and cannot contain spaces' });
    }
    if (!emailRegex.test(email)) {
      logger.warn('Invalid email format');
      return res.status(422).json({ message: 'Invalid email format' });
    }

    // Check if user already exists
    const existingUser = await User.findOne({ where: { email } });
    if (existingUser) {
      logger.warn('User already exists', { email });
      return res.status(400).json({ message: 'User already exists' });
    }

    // Hash the password
    const encrypted_password = await bcrypt.hash(password, 10);

    // Generate verification token and expiration time
    const token = crypto.randomBytes(32).toString('hex');
    const expirationTime = new Date(Date.now() + 1 * 60 * 1000); // Token expires in 1 minute

    // Create new user with verification details
    const newUser = await User.create({
      email,
      password: encrypted_password,
      firstName,
      lastName,
      verificationToken: token,
      tokenExpiration: expirationTime,
      isVerified: false, // Assuming the User model has an isVerified field
    });

    // Publish message to SNS topic for Lambda to send verification email
    const sns = new AWS.SNS({region:"us-east-1"});
    const message = JSON.stringify({
      email: newUser.email,
      token: token,
    });
    const params = {
      Message: message,
      TopicArn: process.env.SNS_TOPIC_ARN,
    };

    try {
      await sns.publish(params).promise();
      logger.info('SNS message published for user verification', { userId: newUser.id });
    } catch (snsError) {
      logger.error('Error publishing SNS message', { error: snsError.message });
    }

    // Calculate request duration
    const requestDiff = process.hrtime(requestStartTime);
    const requestDurationInMs = (requestDiff[0] * 1e9 + requestDiff[1]) / 1e6;
    statsdClient.timing('POST.Create_responsetime', requestDurationInMs);

    // Return success response
    return res.status(201).json({
      description: 'User created successfully. Verification email sent.',
      id: newUser.id,
      firstName: newUser.firstName,
      lastName: newUser.lastName,
      email: newUser.email,
      account_created: moment(newUser.account_created).tz('America/New_York').format(),
      account_updated: moment(newUser.account_updated).tz('America/New_York').format(),
    });
  } catch (error) {
    logger.error('Error creating user', { error: error.message });

    // Measure total request time even on error
    const requestDiff = process.hrtime(requestStartTime);
    const requestDurationInMs = (requestDiff[0] * 1e9 + requestDiff[1]) / 1e6;
    statsdClient.timing('POST.Create_responsetime', requestDurationInMs);

    return res.status(500).json({
      message: 'Error creating user',
    });
  }
});


app.put('/v1/user/self', authenticate, async (req, res) => {
  // Start timing the overall request
  const requestStartTime = process.hrtime();

  try {
    const user = req.user;
    if (!req.body || Object.keys(req.body).length === 0) {
      logger.warn('Empty request body in user update');
      return res.status(422).send('Request body is empty');
    }

    if (
      req.body.email ||
      req.body.account_created ||
      req.body.account_updated ||
      req.body.id
    ) {
      logger.warn('Attempt to modify immutable fields');
      return res.status(400).end();
    }

    if (req.body.firstName) {
      if (req.body.firstName.trim() === '') {
        logger.warn('Firstname cannot be empty');
        return res.status(422).json({ message: 'Firstname cannot be empty' });
      }
      user.firstName = req.body.firstName;
    }
    if (req.body.lastName) {
      if (req.body.lastName.trim() === '') {
        logger.warn('Lastname cannot be empty');
        return res.status(422).json({ message: 'Lastname cannot be empty' });
      }
      user.lastName = req.body.lastName;
    }
    if (req.body.password) {
      if (req.body.password.trim() === '') {
        logger.warn('Password cannot be empty');
        return res.status(422).json({ message: 'Password cannot be empty' });
      }
      if (req.body.password.includes(' ')) {
        logger.warn('Password cannot have space');
        return res.status(422).json({ message: 'Password cannot have space' });
      }
      if (req.body.password.length < 8) {
        logger.warn('Password too short');
        return res
          .status(422)
          .json({ message: 'Password should be at least 8 characters' });
      }
      const encrypted_password = await bcrypt.hash(req.body.password, 10);
      user.password = encrypted_password;
    }
    user.account_updated = moment().tz('America/New_York').toDate();

    // Start timing the database operation
    const dbStartTime = process.hrtime();

    await user.save();

    // Measure DB operation duration for update
    const dbDiffUpdate = process.hrtime(dbStartTime);
    const dbDurationInMsUpdate = (dbDiffUpdate[0] * 1e9 + dbDiffUpdate[1]) / 1e6;

    // Send timing metric for database time
    statsdClient.timing('PUT.Updateuser_database_time', dbDurationInMsUpdate);

    // Measure total request time
    const requestDiff = process.hrtime(requestStartTime);
    const requestDurationInMs = (requestDiff[0] * 1e9 + requestDiff[1]) / 1e6;

    // Send timing metric for response time
    statsdClient.timing('PUT.Updateuser_response', requestDurationInMs);

    logger.info('User updated successfully', { userId: user.id });
    return res.status(204).end();
  } catch (error) {
    logger.error('Error updating user', { error: error.message });

    // Measure total request time even on error
    const requestDiff = process.hrtime(requestStartTime);
    const requestDurationInMs = (requestDiff[0] * 1e9 + requestDiff[1]) / 1e6;
    statsdClient.timing('PUT.Updateuser_response', requestDurationInMs);

    return res.status(500).json({ message: 'Error updating user' });
  }
});

app.delete('/v1/user/self', (req, res) => {
  return res.status(405).end();
});

app.get('/v1/user/self', authenticate, async (req, res) => {
  // Start timing the overall request
  const requestStartTime = process.hrtime();

  try {
    if (Object.keys(req.query).length > 0) {
      logger.warn('Query parameters not allowed in get user');
      return res.status(400).end();
    }
    if (req.get('Content-Length') && parseInt(req.get('Content-Length')) > 0) {
      logger.warn('Content-Length not allowed in get user');
      return res.status(400).end();
    }
    const user = req.user;

    // If you need to perform a database operation here, time it accordingly
    // For example:
    // const dbStartTime = process.hrtime();
    // const user = await User.findOne({ where: { id: req.user.id } });
    // const dbDiff = process.hrtime(dbStartTime);
    // const dbDurationInMs = (dbDiff[0] * 1e9 + dbDiff[1]) / 1e6;
    // statsdClient.timing('GET.Fetchuser_database_time', dbDurationInMs);

    const createtime = moment(user.account_created)
      .tz('America/New_York')
      .format();
    const updatetime = moment(user.account_updated)
      .tz('America/New_York')
      .format();
    logger.info('User data retrieved', { userId: user.id });

    // Measure total request time
    const requestDiff = process.hrtime(requestStartTime);
    const requestDurationInMs = (requestDiff[0] * 1e9 + requestDiff[1]) / 1e6;

    // Send timing metric for response time
    statsdClient.timing('GET.Fetchuser_responsetime', requestDurationInMs);

    return res.status(200).json({
      id: user.id,
      firstName: user.firstName,
      lastName: user.lastName,
      email: user.email,
      account_created: createtime,
      account_updated: updatetime,
    });
  } catch (error) {
    logger.error('Error fetching user information', { error: error.message });

    // Measure total request time even on error
    const requestDiff = process.hrtime(requestStartTime);
    const requestDurationInMs = (requestDiff[0] * 1e9 + requestDiff[1]) / 1e6;
    statsdClient.timing('GET.Fetchuser_responsetime', requestDurationInMs);

    return res.status(500).json({ message: 'Error fetching user information' });
  }
});

// AWS S3 configuration (ensure AWS credentials are set via IAM role or environment variables)
const s3 = new AWS.S3({
  region: process.env.AWS_REGION,
});

const upload = multer({ storage: multer.memoryStorage() });

// Upload user picture
app.post('/v1/user/self/pic', authenticate, upload.single('image'), async (req, res) => {
  // Start timing the overall request
  const requestStartTime = process.hrtime();

  try {
    logger.info('Uploading user picture', { userId: req.user.id });
    const user = req.user;

    // Check if the user already has an uploaded image
    if (user.file_name && user.url) {
      logger.warn('User already has an uploaded image', { userId: user.id });
      return res.status(409).json({ message: 'User already has an uploaded image' });
    }

    if (!req.file) {
      logger.warn('No image file uploaded', { userId: user.id });
      return res.status(400).json({ message: 'No image file uploaded' });
    }

    // Generate unique filename
    const fileName = `${user.id}-${Date.now()}-${req.file.originalname}`;

    // Define S3 upload parameters
    const params = {
      Bucket: process.env.S3_BUCKET_NAME,
      Key: fileName,
      Body: req.file.buffer,
      ContentType: req.file.mimetype,
    };

    // Start timing the S3 upload
    const s3StartTime = process.hrtime();

    // Upload the file to S3
    const s3Response = await s3.upload(params).promise();

    // Measure S3 upload duration
    const s3Diff = process.hrtime(s3StartTime);
    const s3DurationInMs = (s3Diff[0] * 1e9 + s3Diff[1]) / 1e6;

    // Send timing metric for database time (S3 upload)
    statsdClient.timing('POST.addpic_database_time', s3DurationInMs);

    // Save the S3 URL to the database
    user.file_name = fileName;
    user.url = s3Response.Location;

    await user.save();

    logger.info('Image uploaded successfully', { userId: user.id, imageUrl: s3Response.Location });

    // Measure total request time
    const requestDiff = process.hrtime(requestStartTime);
    const requestDurationInMs = (requestDiff[0] * 1e9 + requestDiff[1]) / 1e6;

    // Send timing metric for response time
    statsdClient.timing('POST.addpic_responsetime', requestDurationInMs);

    return res.status(200).json(
      { url: s3Response.Location, 
        file: fileName,
        id: user.id,
        user_id: user.id
    });
  } catch (error) {
    logger.error('Error uploading image', { error: error.message });

    // Measure total request time even on error
    const requestDiff = process.hrtime(requestStartTime);
    const requestDurationInMs = (requestDiff[0] * 1e9 + requestDiff[1]) / 1e6;
    statsdClient.timing('POST.addpic_responsetime', requestDurationInMs);

    return res.status(500).json({ message: 'Error uploading image' });
  }
});

app.get('/v1/user/verify', async (req, res) => {
  const { token } = req.query;

  if (!token) {
    logger.warn('No token provided for verification');
    return res.status(400).json({ message: 'Verification token is required' });
  }

  try {
    const user = await User.findOne({ where: { verificationToken: token } });

    // Check if user exists and token is valid
    if (!user || user.tokenExpiration < new Date()) {
      logger.warn('Invalid or expired token');
      return res.status(400).json({ message: 'Invalid or expired token' });
    }

    // Mark user as verified
    await user.update({
      isVerified: true,
      verificationToken: null,
      tokenExpiration: null,
    });

    logger.info('User verified successfully', { email: user.email });
    return res.status(200).json({ message: 'Email verified successfully' });
  } catch (error) {
    logger.error('Error verifying email', { error: error.message });
    return res.status(500).json({ message: 'Internal server error' });
  }
});



// Delete user picture
app.delete('/v1/user/self/pic', authenticate, async (req, res) => {
  // Start timing the overall request
  const requestStartTime = process.hrtime();

  try {
    logger.info('Deleting user picture', { userId: req.user.id });
    const user = req.user;

    // Check if there is an image to delete
    if (!user.url || !user.file_name) {
      logger.warn('No image found to delete', { userId: user.id });
      return res.status(404).json({ message: 'No image found to delete' });
    }

    // S3 delete parameters
    const params = {
      Bucket: process.env.S3_BUCKET_NAME,
      Key: user.file_name,
    };

    // Start timing the S3 delete
    const s3StartTime = process.hrtime();

    // Delete from S3
    await s3.deleteObject(params).promise();

    // Measure S3 delete duration
    const s3Diff = process.hrtime(s3StartTime);
    const s3DurationInMs = (s3Diff[0] * 1e9 + s3Diff[1]) / 1e6;

    // Send timing metric for database time (S3 delete)
    statsdClient.timing('DELETE.removepic_database_time', s3DurationInMs);

    // Clear the URL and fileName from the database
    user.url = null;
    user.file_name = null;

    await user.save();

    logger.info('Image deleted successfully', { userId: user.id });

    // Measure total request time
    const requestDiff = process.hrtime(requestStartTime);
    const requestDurationInMs = (requestDiff[0] * 1e9 + requestDiff[1]) / 1e6;

    // Send timing metric for response time
    statsdClient.timing('DELETE.removepic_responsetime', requestDurationInMs);

    return res.status(204).end();
  } catch (error) {
    logger.error('Error deleting image', { error: error.message });

    // Measure total request time even on error
    const requestDiff = process.hrtime(requestStartTime);
    const requestDurationInMs = (requestDiff[0] * 1e9 + requestDiff[1]) / 1e6;
    statsdClient.timing('DELETE.removepic_responsetime', requestDurationInMs);

    return res.status(500).json({ message: 'Error deleting image' });
  }
});

// Start the server
(async () => {
  try {
    await sequelize.sync({ alter: true });
    const server = app.listen(process.env.PORT, () => {
      logger.info('Server running', { port: process.env.PORT });
    });

    server.on('error', (e) => {
      if (e.code === 'EADDRINUSE') {
        app.listen(process.env.DEFAULT_PORT, '0.0.0.0', () => {
          logger.info('Server running on fallback port', { port: process.env.DEFAULT_PORT });
        });
      } else {
        logger.error('Server error', { error: e.message });
      }
    });
  } catch (error) {
    logger.error('Error synchronizing the database', { error: error.message });
  }
})();

export { app, sequelize, User };