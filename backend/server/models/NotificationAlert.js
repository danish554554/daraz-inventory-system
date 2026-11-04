const mongoose = require("mongoose");

const notificationAlertSchema = new mongoose.Schema(
  {
    type: {
      type: String,
      required: true,
      trim: true
    },
    title: {
      type: String,
      required: true,
      trim: true
    },
    body: {
      type: String,
      required: true,
      trim: true
    },
    data: {
      type: mongoose.Schema.Types.Mixed,
      default: {}
    },
    read: {
      type: Boolean,
      default: false
    }
  },
  { timestamps: true }
);

notificationAlertSchema.index({ createdAt: -1 });

module.exports = mongoose.model("NotificationAlert", notificationAlertSchema);
