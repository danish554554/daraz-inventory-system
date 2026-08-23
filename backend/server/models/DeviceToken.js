const mongoose = require("mongoose");

const deviceTokenSchema = new mongoose.Schema(
  {
    token: {
      type: String,
      required: true,
      unique: true,
      trim: true
    },
    platform: {
      type: String,
      enum: ["android", "ios", "web", "unknown"],
      default: "android"
    },
    user_id: {
      type: String,
      default: "admin",
      trim: true
    },
    is_active: {
      type: Boolean,
      default: true
    },
    last_active_at: {
      type: Date,
      default: Date.now
    }
  },
  { timestamps: true }
);

module.exports = mongoose.model("DeviceToken", deviceTokenSchema);
