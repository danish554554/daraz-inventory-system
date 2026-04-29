function escapeCsvValue(value) {
  if (value === null || value === undefined) return '';
  const stringValue = String(value);
  if (/[",\n]/.test(stringValue)) {
    return `"${stringValue.replace(/"/g, '""')}"`;
  }
  return stringValue;
}

function toCsv(rows = []) {
  if (!Array.isArray(rows) || rows.length === 0) {
    return 'No data available\n';
  }

  const headers = Array.from(
    rows.reduce((set, row) => {
      Object.keys(row || {}).forEach((key) => set.add(key));
      return set;
    }, new Set())
  );

  const lines = [headers.join(',')];

  for (const row of rows) {
    lines.push(headers.map((header) => escapeCsvValue(row?.[header])).join(','));
  }

  return `${lines.join('\n')}\n`;
}

function startOfDay(dateInput) {
  const date = dateInput ? new Date(dateInput) : new Date();
  if (Number.isNaN(date.getTime())) {
    const fallback = new Date();
    fallback.setHours(0, 0, 0, 0);
    return fallback;
  }
  date.setHours(0, 0, 0, 0);
  return date;
}

function endOfDay(dateInput) {
  const date = startOfDay(dateInput);
  date.setDate(date.getDate() + 1);
  return date;
}

module.exports = {
  toCsv,
  startOfDay,
  endOfDay
};
