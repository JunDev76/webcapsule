/* global module */
module.exports = {
  dependency: {
    platforms: {
      android: {
        sourceDir: "./android",
        packageImportPath:
          "import com.webcapsule.reactnative.WebCapsulePackage;",
        packageInstance: "new WebCapsulePackage()",
      },
    },
  },
};
