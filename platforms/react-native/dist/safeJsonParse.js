"use strict";
// safeJsonParse — wraps JSON.parse and reports failures to UniTrack.
//
// Usage:
//   const user = safeJsonParse<User>('User', responseText);
//   if (user) { /* ... */ }
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.default = safeJsonParse;
const index_1 = __importDefault(require("./index"));
function safeJsonParse(targetType, raw) {
    var _a, _b, _c;
    try {
        return JSON.parse(raw);
    }
    catch (e) {
        const stack = ((_a = e === null || e === void 0 ? void 0 : e.stack) !== null && _a !== void 0 ? _a : '').split('\n').slice(0, 8).join('\n');
        index_1.default.track('json_parse_error', {
            type: targetType,
            error: `${(_b = e === null || e === void 0 ? void 0 : e.name) !== null && _b !== void 0 ? _b : 'Error'}: ${(_c = e === null || e === void 0 ? void 0 : e.message) !== null && _c !== void 0 ? _c : ''}`,
            stack,
            data_preview: raw.slice(0, 200),
        });
        return null;
    }
}
//# sourceMappingURL=safeJsonParse.js.map