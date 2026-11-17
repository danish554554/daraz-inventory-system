const mongoose = require("mongoose");

// Prevent Mongoose 8/9 deprecation warning: the 'new' option for findOneAndUpdate() is deprecated
const originalEmitWarning = process.emitWarning;
process.emitWarning = function(warning, ...args) {
  if (
    (typeof warning === 'string' && warning.includes("the 'new' option for 'findOneAndUpdate()'")) ||
    (warning && warning.message && warning.message.includes("the 'new' option for 'findOneAndUpdate()'"))
  ) {
    return;
  }
  return originalEmitWarning.call(process, warning, ...args);
};

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