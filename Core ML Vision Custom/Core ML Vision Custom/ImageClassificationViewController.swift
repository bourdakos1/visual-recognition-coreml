/**
 * Copyright IBM Corporation 2017, 2018
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import UIKit
import AVFoundation
import VisualRecognitionV3

struct VisualRecognitionConstants {
    // Instantiation with `api_key` works only with Visual Recognition service instances created before May 23, 2018. Visual Recognition instances created after May 22 use the IAM `apikey`.
    static let apikey = "oSPvI_VA3hWIdCutkfggdtxvXgItQJJm-ff1fOGKMd2F"     // The IAM apikey
    static let api_key = ""    // The apikey
    static let modelIds = ["DefaultCustomModel_936213647"]
    static let version = "2018-03-19"
}

class ImageClassificationViewController: UIViewController {
    
    // MARK: - IBOutlets
    
    @IBOutlet weak var cameraView: UIView!
    @IBOutlet weak var imageView: UIImageView!
    @IBOutlet weak var simulatorTextView: UITextView!
    @IBOutlet weak var captureButton: UIButton!
    @IBOutlet weak var updateModelButton: UIButton!
    @IBOutlet weak var choosePhotoButton: UIButton!
    @IBOutlet weak var closeButton: UIButton!
    @IBOutlet weak var alphaSlider: UISlider!
    @IBOutlet weak var confidenceLabel: UILabel!
    
    // MARK: - Variable Declarations
    
    let visualRecognition: VisualRecognition = {
        if !VisualRecognitionConstants.api_key.isEmpty {
            return VisualRecognition(apiKey: VisualRecognitionConstants.api_key, version: VisualRecognitionConstants.version)
        }
        return VisualRecognition(version: VisualRecognitionConstants.version, apiKey: VisualRecognitionConstants.apikey)
    }()
    
    let photoOutput = AVCapturePhotoOutput()
    lazy var captureSession: AVCaptureSession? = {
        guard let backCamera = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: backCamera) else {
                return nil
        }
        
        let captureSession = AVCaptureSession()
        captureSession.sessionPreset = .high
        captureSession.addInput(input)
        
        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
            let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
            previewLayer.frame = CGRect(x: view.bounds.minX, y: view.bounds.minY, width: view.bounds.width, height: view.bounds.width)
            // `.resize` allows the camera to fill the screen on the iPhone X.
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.connection?.videoOrientation = .portrait
            cameraView.layer.addSublayer(previewLayer)
            return captureSession
        }
        return nil
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        captureSession?.startRunning()
        resetUI()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let localModels = try? visualRecognition.listLocalModels() else {
            return
        }
        
        var modelsToUpdate = [String]()
        
        for modelId in VisualRecognitionConstants.modelIds {
            // Pull down model if none on device
            // This only checks if the model is downloaded, we need to change this if we want to check for updates when then open the app
            if !localModels.contains(modelId) {
                modelsToUpdate.append(modelId)
            }
        }
        
        if modelsToUpdate.count > 0 {
            updateLocalModels(ids: modelsToUpdate)
        }
    }
    
    // MARK: - Model Methods
    
    func updateLocalModels(ids modelIds: [String]) {
        SwiftSpinner.show("Compiling model...")
        let dispatchGroup = DispatchGroup()
        // If the array is empty the dispatch group won't be notified so we might end up with an endless spinner
        dispatchGroup.enter()
        for modelId in modelIds {
            dispatchGroup.enter()
            let failure = { (error: Error) in
                dispatchGroup.leave()
                DispatchQueue.main.async {
                    self.modelUpdateFail(modelId: modelId, error: error)
                }
            }
            
            let success = {
                dispatchGroup.leave()
            }
            
            visualRecognition.updateLocalModel(classifierID: modelId, failure: failure, success: success)
        }
        dispatchGroup.leave()
        dispatchGroup.notify(queue: .main) {
            SwiftSpinner.hide()
        }
    }

    func presentPhotoPicker(sourceType: UIImagePickerControllerSourceType) {
        let picker = UIImagePickerController()
        picker.delegate = self
        picker.sourceType = sourceType
        present(picker, animated: true)
    }
    
    // MARK: - Image Classification
    
    func classifyImage(_ image: UIImage, localThreshold: Double = 0.0) {
        let sliderValue = Double(self.alphaSlider.value)
        
        var editedImage = cropToCenter(image: image)
        editedImage = resizeImage(image: editedImage, targetSize: CGSize(width: 224, height: 224))
        
        DispatchQueue.main.async {
            self.showResultsUI(for: editedImage)
            SwiftSpinner.show("analyzing")
        }
        
        var originalConf = 0.0
        visualRecognition.classifyWithLocalModel(image: editedImage, classifierIDs: VisualRecognitionConstants.modelIds, threshold: localThreshold, failure: nil) { classifiedImages in

            // Make sure that an image was successfully classified.
            guard let classifiedImage = classifiedImages.images.first,
                let classifier = classifiedImage.classifiers.first else {
                    return
            }

            let usbClass = classifier.classes.filter({ return $0.className.uppercased() == "USB" })

            guard let usbClassSingle = usbClass.first,
                let score = usbClassSingle.score else {
                    return
            }

            originalConf = score
        }
        
        
        imageView.contentMode = .scaleAspectFit
        
        let dispatchGroup = DispatchGroup()
        
        var confidences = [[Double]](repeating: [Double](repeating: -1, count: 17), count: 17)
        
        dispatchGroup.enter()
    
        DispatchQueue.global(qos: .background).async {
            
            for down in 0 ..< 11 {
                for right in 0 ..< 11 {
                    confidences[down + 3][right + 3] = 0
                    print("\(down) - \(right)")
                    dispatchGroup.enter()
                    let maskedImage = self.drawRectangleOnImage(image: editedImage, right: right, down: down)
                    self.visualRecognition.classifyWithLocalModel(image: maskedImage, classifierIDs: VisualRecognitionConstants.modelIds, threshold: localThreshold, failure: nil) { [down, right] classifiedImages in
                        
                        // Make sure that an image was successfully classified.
                        guard let classifiedImage = classifiedImages.images.first,
                            let classifier = classifiedImage.classifiers.first else {
                                dispatchGroup.leave()
                                return
                        }
                        
                        let usbClass = classifier.classes.filter({ return $0.className.uppercased() == "USB" })
                        
                        guard let usbClassSingle = usbClass.first,
                            let score = usbClassSingle.score else {
                                dispatchGroup.leave()
                                return
                        }
                        
                        print("\(down) - \(right)")
                        confidences[down + 3][right + 3] = score
                        dispatchGroup.leave()
                    }
                }
            }
            dispatchGroup.leave()
        
            dispatchGroup.notify(queue: .main) {
                print(confidences)
                print(originalConf)
                
                self.editedImage = editedImage
                self.confidences = confidences
                self.originalConf = originalConf
                
                let final = self.renderImage(image: editedImage, confidences: confidences, originalConf: originalConf, alpha: sliderValue)
                
                self.imageView.image = final
                self.confidenceLabel.text = "Confidence: \(originalConf)"
                SwiftSpinner.hide()
            }
        }
        
    }
    
    var editedImage = UIImage()
    var confidences = [[Double]]()
    var originalConf = 0.0
    
    func renderImage(image: UIImage, confidences: [[Double]], originalConf: Double, alpha: Double) -> UIImage {
        let size = image.size
        UIGraphicsBeginImageContextWithOptions(size, true, UIScreen.main.scale)
        
        image.draw(at: .zero, blendMode: .normal, alpha: 1)
                
        for down in 0 ..< 14 {
            for right in 0 ..< 14 {
                let rectangle = CGRect(x: right * 16, y: down * 16, width: 16, height: 16)
                
                let kernel = confidences[down + 0...down + 3].map({ $0[right + 0...right + 3] })
            
                var sum = 0.0
                var count = 16.0
                for row in kernel {
                    for score in row {
                        if score == -1 {
                            count -= 1
                        } else {
                            sum += score
                        }
                    }
                }
                
                let mean = sum / count
                
                let newalpha = 1 - max(originalConf - mean, 0) * 5
                let cappedAlpha = min(max(newalpha, 0), 1)
                print(cappedAlpha)
                
                UIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(cappedAlpha * alpha)).setFill()
                UIRectFillUsingBlendMode(rectangle, .normal)
                
            }
        }
        
        let newImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return newImage
    }
    
    func drawRectangleOnImage(image: UIImage, right: Int, down: Int) -> UIImage {
        let size = image.size
        UIGraphicsBeginImageContextWithOptions(size, true, UIScreen.main.scale)
        
        image.draw(at: .zero)
        
        let rectangle = CGRect(x: right * 16, y: down * 16, width: 64, height: 64)
        
        UIColor(red: 1, green: 0, blue: 1, alpha: 1).setFill()
        UIRectFill(rectangle)
        
        let newImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return newImage
    }
    
    func resizeImage(image: UIImage, targetSize: CGSize) -> UIImage {
        let size = image.size
        
        let widthRatio  = targetSize.width  / size.width
        let heightRatio = targetSize.height / size.height
        
        // Figure out what our orientation is, and use that to form the rectangle
        var newSize: CGSize
        if(widthRatio > heightRatio) {
            newSize = CGSize(width: size.width * heightRatio, height: size.height * heightRatio)
        } else {
            newSize = CGSize(width: size.width * widthRatio,  height: size.height * widthRatio)
        }
        
        // This is the rect that we've calculated out and this is what is actually used below
        let rect = CGRect(x: 0, y: 0, width: newSize.width, height: newSize.height)
        
        // Actually do the resizing to the rect using the ImageContext stuff
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: rect)
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return newImage!
    }
    
    func cropToCenter(image: UIImage) -> UIImage {
        let contextImage: UIImage = UIImage(cgImage: image.cgImage!)
        
        let contextSize: CGSize = contextImage.size
        var posX: CGFloat = 0.0
        var posY: CGFloat = 0.0
        var cgwidth: CGFloat = contextSize.width
        var cgheight: CGFloat = contextSize.height
        
        // See what size is longer and create the center off of that
        if contextSize.width > contextSize.height {
            posX = ((contextSize.width - contextSize.height) / 2)
            posY = 0
            cgwidth = contextSize.height
            cgheight = contextSize.height
        } else if contextSize.width < contextSize.height {
            posX = 0
            posY = ((contextSize.height - contextSize.width) / 2)
            cgwidth = contextSize.width
            cgheight = contextSize.width
        }
        
        // crop image to square
        let rect: CGRect = CGRect(x: posX, y: posY, width: cgwidth, height: cgheight)
        let imageRef: CGImage = contextImage.cgImage!.cropping(to: rect)!
        let image: UIImage = UIImage(cgImage: imageRef, scale: image.scale, orientation: image.imageOrientation)
        
        return image
    }
    
    func dismissResults() {
        push(results: [], position: .closed)
    }
    
    func push(results: [VisualRecognitionV3.ClassifierResult], position: PulleyPosition = .partiallyRevealed) {
        guard let drawer = pulleyViewController?.drawerContentViewController as? ResultsTableViewController else {
            return
        }
        drawer.classifications = results
        pulleyViewController?.setDrawerPosition(position: position, animated: true)
        drawer.tableView.reloadData()
    }
    
    func showResultsUI(for image: UIImage) {
        imageView.image = image
        imageView.isHidden = false
        simulatorTextView.isHidden = true
        closeButton.isHidden = false
        captureButton.isHidden = true
        choosePhotoButton.isHidden = true
        updateModelButton.isHidden = true
        alphaSlider.isHidden = false
        confidenceLabel.isHidden = false
    }
    
    func resetUI() {
        if captureSession != nil {
            simulatorTextView.isHidden = true
            imageView.isHidden = true
            captureButton.isHidden = false
        } else {
            imageView.image = UIImage(named: "Background")
            simulatorTextView.isHidden = false
            imageView.isHidden = false
            captureButton.isHidden = true
        }
        confidenceLabel.isHidden = true
        alphaSlider.isHidden = true
        closeButton.isHidden = true
        choosePhotoButton.isHidden = false
        updateModelButton.isHidden = false
        dismissResults()
    }
    
    // MARK: - IBActions
    
    @IBAction func sliderValueChanged(_ sender: UISlider) {
        let currentValue = Double(sender.value)
        let final = self.renderImage(image: editedImage, confidences: confidences, originalConf: originalConf, alpha: currentValue)
        imageView.image = final
    }
    
    @IBAction func capturePhoto() {
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }
    
    @IBAction func updateModel(_ sender: Any) {
        updateLocalModels(ids: VisualRecognitionConstants.modelIds)
    }
    
    @IBAction func presentPhotoPicker() {
        let picker = UIImagePickerController()
        picker.delegate = self
        picker.sourceType = .photoLibrary
        present(picker, animated: true)
    }
    
    @IBAction func reset() {
        resetUI()
    }
}

// MARK: - Error Handling

extension ImageClassificationViewController {
    func showAlert(_ alertTitle: String, alertMessage: String) {
        let alert = UIAlertController(title: alertTitle, message: alertMessage, preferredStyle: UIAlertControllerStyle.alert)
        alert.addAction(UIAlertAction(title: "Dismiss", style: UIAlertActionStyle.default, handler: nil))
        self.present(alert, animated: true, completion: nil)
    }
    
    func modelUpdateFail(modelId: String, error: Error) {
        let error = error as NSError
        var errorMessage = ""
        
        // 0 = probably wrong api key
        // 404 = probably no model
        // -1009 = probably no internet
        
        switch error.code {
        case 0:
            errorMessage = "Please check your Visual Recognition API key in `Credentials.plist` and try again."
        case 404:
            errorMessage = "We couldn't find the model with ID: \"\(modelId)\""
        case 500:
            errorMessage = "Internal server error. Please try again."
        case -1009:
            errorMessage = "Please check your internet connection."
        default:
            errorMessage = "Please try again."
        }
        
        // TODO: Do some more checks, does the model exist? is it still training? etc.
        // The service's response is pretty generic and just guesses.
        
        showAlert("Unable to download model", alertMessage: errorMessage)
    }
}

// MARK: - UIImagePickerControllerDelegate

extension ImageClassificationViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [String: Any]) {
        picker.dismiss(animated: true)
        
        guard let image = info[UIImagePickerControllerOriginalImage] as? UIImage else {
            return
        }
        
        classifyImage(image)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension ImageClassificationViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            print(error.localizedDescription)
            return
        }
        guard let photoData = photo.fileDataRepresentation(),
            let image = UIImage(data: photoData) else {
            return
        }
        
        classifyImage(image)
    }
}


