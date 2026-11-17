const mongoose = require("mongoose");

// Prevent Mongoose 8/9 deprecation warning: the 'new' option for findOneAndUpdate() is deprecated
mongoose.set("returnDocument", "before");

const connectDB = async () => {
  try {
    const mongoUri = process.env.MONGO_URI || process.env.MONGODB_URI;

    console.log("Mongo URI loaded:", mongoUri ? "YES" : "NO");

    await mongoose.connect(mongoUri);
    console.log("MongoDB Connected");
  } catch (error) {
    console.error("MongoDB Connection Error:", error.message);
    process.exit(1);
  }
};

module.exports = connectDB;