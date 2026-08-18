import { describe, expect, it } from "vitest";
import { canonicalJson } from "../src/index.js";

// RFC 8785 sections 3.2.2 and 3.2.3 official serialization examples.
describe("RFC 8785 official vectors", () => {
  it("serializes the RFC number sample", () => {
    expect(
      canonicalJson({ numbers: [333333333.3333333, 1e30, 4.5, 2e-3, 1e-27] }),
    ).toBe('{"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27]}');
  });
  it("sorts the RFC UTF-16 property sample", () => {
    const value = {
      "\u20ac": "Euro Sign",
      "\r": "Carriage Return",
      "\ufb33": "Hebrew Letter Dalet With Dagesh",
      "1": "One",
      "😀": "Emoji: Grinning Face",
      "\u0080": "Control",
      ö: "Latin Small Letter O With Diaeresis",
    };
    expect(canonicalJson(value)).toBe(
      '{"\\r":"Carriage Return","1":"One","":"Control","ö":"Latin Small Letter O With Diaeresis","€":"Euro Sign","😀":"Emoji: Grinning Face","דּ":"Hebrew Letter Dalet With Dagesh"}',
    );
  });
});
