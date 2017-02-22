/**
 * Copyright IBM Corporation 2017
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

import Foundation
#if os(Linux)
    import Dispatch
#endif
import LoggerAPI
import Kitura
import KituraWebSocket
import SwiftyJSON
import Configuration
import SwiftMetrics
import SwiftMetricsBluemix
import CloudFoundryEnv
import AlertNotifications
import CircuitBreaker

public class Controller {
    enum DemoError: Error {
        case BadHostURL, InvalidPort
    }
    
    let config: Configuration
    let router: Router
    let credentials: ServiceCredentials

    // Metrics variables
    var metrics: SwiftMetrics
    var monitor: SwiftMonitor
    var bluemixMetrics: AutoScalar
    var metricsDict: [String: Any]
    var currentMemoryUser: MemoryUser? = nil
    var cpuUser: CPUUser
    var throughputGenerator: ThroughputGenerator

    // Current delay on JSON response.
    var jsonDelayTime: UInt32
    
    // Circuit breaker.
    let breaker: CircuitBreaker<(URL, RouterResponse, () -> Void), Void>
    var wsConnections: [String: WebSocketConnection]  = [:]
    var broadcastQueue: DispatchQueue
    var jsonEndpointHostURL: String = "http://kitura-starter-spatterdashed-preliberality.stage1.mybluemix.net"

    // Location of the cloud config file.
    let cloudConfigFile = "cloud_config.json"

    var port: Int {
        get { return config.getPort() }
    }

    var url: String {
        get { return config.getURL() }
    }

    init() throws {
        // AppEnv configuration.
        self.config = try Configuration(withFile: cloudConfigFile)
        self.metricsDict = [:]
        self.router = Router()
        self.cpuUser = CPUUser()
        self.throughputGenerator = ThroughputGenerator()

        // Credentials for the Alert Notifications SDK.
        guard let alertCredentials = config.getCredentials(forService: "SwiftEnterpriseDemo-Alert"),
            let url = alertCredentials["url"] as? String,
            let name = alertCredentials["name"] as? String,
            let password = alertCredentials["password"] as? String else {
                throw AlertNotificationError.credentialsError("Failed to obtain credentials for alert service.")
        }
        self.credentials = ServiceCredentials(url: url, name: name, password: password)

        // Demo variables.
        self.jsonDelayTime = 0
        
        // Circuit breaker.
        self.breaker = CircuitBreaker(timeout: 10, maxFailures: 5, fallback: circuitTimeoutCallback, commandWrapper: circuitRequestWrapper)
        self.broadcastQueue = DispatchQueue(label: "circuitBroadcastQueue", qos: DispatchQoS.userInitiated)

        // SwiftMetrics configuration.
        self.metrics = try SwiftMetrics()
        self.monitor = self.metrics.monitor()
        self.bluemixMetrics = AutoScalar(swiftMetricsInstance: self.metrics)
        self.monitor.on(recordCPU)
        self.monitor.on(recordMem)
        
        // Get auto-scaling policy.
        getAutoScalingPolicy(forAppID: "1fca7d89-c9a8-456f-946c-10963cc1897d")

        // Router configuration.
        self.router.all("/", middleware: BodyParser())
        self.router.get("/", middleware: StaticFileServer(path: "./public"))
        self.router.get("/initData", handler: getInitDataHandler)
        self.router.get("/metrics", handler: getMetricsHandler)
        self.router.post("/memory", handler: requestMemoryHandler)
        self.router.post("/cpu", handler: requestCPUHandler)
        self.router.post("/responseTime", handler: responseTimeHandler)
        self.router.get("/requestJSON", handler: requestJSONHandler)
        self.router.post("/throughput", handler: requestThroughputHandler)
        self.router.post("/changeEndpoint", handler: changeEndpointHandler)
        self.router.get("/changeCircuit/:state", handler: changeCircuitHandler)
        self.router.get("/invokeCircuit", handler: invokeCircuitHandler)
    }

    // Take CPU data and store it in our metrics dictionary.
    func recordCPU(cpu: CPUData) {
        metricsDict["cpuUsedByApplication"] = cpu.percentUsedByApplication * 100
        metricsDict["cpuUsedBySystem"] = cpu.percentUsedBySystem * 100
    }

    // Take memory data and store it in our metrics dictionary.
    func recordMem(mem: MemData) {
        metricsDict["totalRAMOnSystem"] = mem.totalRAMOnSystem
        metricsDict["totalRAMUsed"] = mem.totalRAMUsed
        metricsDict["totalRAMFree"] = mem.totalRAMFree
        metricsDict["applicationAddressSpaceSize"] = mem.applicationAddressSpaceSize
        metricsDict["applicationPrivateSize"] = mem.applicationPrivateSize
        metricsDict["applicationRAMUsed"] = mem.applicationRAMUsed
    }
    
    // Obtain information about the current auto-scaling policy.
    func getAutoScalingPolicy(forAppID id: String) {
        guard let policyURL = URL(string: "http://api.ibm.com/v1/autoscaler/apps/%7B\(id)%7D/policy") else {
            Log.error("Invalid URL. Coudl not acquire auto-scaling policy.")
            return
        }
        networkRequest(url: policyURL, method: "GET") {
            data, response, error in
            if let data = data {
                print("\(String(data: data, encoding: .utf8))")
            }
            if let response = response {
                print("\(response)")
            }
            if let error = error {
                print("\(error)")
            }
            return
        }
    }
    
    // Start regularly sending out information on the state of the circuit.
    func startCircuitBroadcast() {
        let broadcastWorkItem = {
            while true {
                broadcastCircuitStatus(breaker: self.breaker)
                sleep(10)
            }
        }
        self.broadcastQueue.async(execute: broadcastWorkItem)
    }

    public func getInitDataHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
        var initDict: [String: Any] = [:]
        initDict["monitoringURL"] = "/swiftdash"
        let appData = self.config.getAppEnv()
        if appData.isLocal == false, let moreAppData = appData.getApp(), let appName = appData.name {
            initDict["monitoringURL"] = "https://console.ng.bluemix.net/monitoring/index?dashboard=console.dashboard.page.appmonitoring1&nav=false&ace_config=%7B%22spaceGuid%22%3A%22\(moreAppData.spaceId)%22%2C%22appGuid%22%3A%22\(moreAppData.id)%22%2C%22bluemixUIVersion%22%3A%22Atlas%22%2C%22idealHeight%22%3A571%2C%22theme%22%3A%22bx--global-light-ui%22%2C%22appName%22%3A%22\(appName)%22%2C%22appRoutes%22%3A%22\(moreAppData.uris[0])%22%7D&bluemixNav=true"
        }
        if let totalRAM = metricsDict["totalRAMOnSystem"] {
            initDict["totalRAM"] = totalRAM
        }
        if let initData = try? JSONSerialization.data(withJSONObject: initDict, options: []) {
            response.status(.OK).send(data: initData)
        } else {
            response.status(.internalServerError).send("Could not retrieve application data.")
        }
        next()
    }

    public func getMetricsHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
        if let metricsData = try? JSONSerialization.data(withJSONObject: metricsDict, options: []) {
            response.status(.OK).send(data: metricsData)
        } else {
            response.status(.internalServerError).send("Could not retrieve metrics data.")
        }
        next()
    }

    public func requestMemoryHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
        guard let parsedBody = request.body else {
            Log.error("Bad request. Could not utilize memory.")
            response.status(.badRequest).send("Bad request. Could not utilize memory.")
            next()
            return
        }

        switch parsedBody {
        case .json(let memObject):
            guard memObject.type == .number else {
                fallthrough
            }

            if let memoryAmount = memObject.object as? Int {
                requestMemory(inBytes: memoryAmount, response: response, next: next)
            } else if let memoryNSAmount = memObject.object as? NSNumber {
                let memoryAmount = Int(memoryNSAmount)
                requestMemory(inBytes: memoryAmount, response: response, next: next)
            } else {
                fallthrough
            }
        default:
            Log.error("Bad value received. Could not utilize memory.")
            response.status(.badRequest).send("Bad request. Could not utilize memory.")
            next()
        }
    }

    public func requestMemory(inBytes memoryAmount: Int, response: RouterResponse, next: @escaping () -> Void) {
        self.currentMemoryUser = nil

        guard memoryAmount > 0 else {
            let _ = response.send(status: .OK)
            next()
            return
        }

        self.currentMemoryUser = MemoryUser(usingBytes: memoryAmount)
        guard memoryAmount > 100_000_000 else {
            let _ = response.send(status: .OK)
            next()
            return
        }

        sendAlert(type: .MemoryAlert, appEnv: self.config.getAppEnv(), usingCredentials: self.credentials) {
            alert, err in
            if let err = err {
                Log.error("Could not send alert: \(err)")
            } else {
                Log.verbose("Alert sent.")
            }
            let _ = response.send(status: .OK)
            next()
        }
    }

    public func requestCPUHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
        guard let parsedBody = request.body else {
            Log.error("Bad request. Could not utilize CPU.")
            response.status(.badRequest).send("Bad request. Could not utilize CPU.")
            next()
            return
        }

        switch parsedBody {
        case .json(let cpuObject):
            guard cpuObject.type == .number else {
                fallthrough
            }

            if let cpuPercent = cpuObject.object as? Double {
                self.cpuUser.utilizeCPU(cpuPercent: cpuPercent)
                let _ = response.send(status: .OK)
            } else if let cpuNSPercent = cpuObject.object as? NSNumber {
                let cpuPercent = Double(cpuNSPercent)
                self.cpuUser.utilizeCPU(cpuPercent: cpuPercent)
                let _ = response.send(status: .OK)
            } else {
                fallthrough
            }
        default:
            Log.error("Bad value received. Could not utilize CPU.")
            response.status(.badRequest).send("Bad request. Could not utilize CPU.")
        }
        next()
    }

    public func responseTimeHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
        guard let parsedBody = request.body else {
            Log.error("Bad request. Could not change delay time.")
            response.status(.badRequest).send("Bad request. Could not change delay time.")
            next()
            return
        }

        switch parsedBody {
        case .json(let responseTimeObject):
            guard responseTimeObject.type == .number else {
                fallthrough
            }

            if let responseTime = responseTimeObject.object as? UInt32 {
                self.jsonDelayTime = responseTime
                let _ = response.send(status: .OK)
            } else if let NSResponseTime = responseTimeObject.object as? NSNumber {
                let responseTime = UInt32(Int(NSResponseTime))
                self.jsonDelayTime = responseTime
                let _ = response.send(status: .OK)
            } else {
                fallthrough
            }
        default:
            Log.error("Bad value received. Could not change delay time.")
            response.status(.badRequest).send("Bad request. Could not change delay time.")
        }
        next()
    }

    public func requestJSONHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) {
        sleep(self.jsonDelayTime)
        let responseDict = ["delay": Int(self.jsonDelayTime)]
        if let responseData = try? JSONSerialization.data(withJSONObject: responseDict, options: []) {
            response.status(.OK).send(data: responseData)
        } else {
            response.status(.internalServerError).send("Could not retrieve response data.")
        }
        next()
    }
    
    public func requestThroughputHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
        guard let parsedBody = request.body else {
            Log.error("Bad request. Could not generate throughout.")
            response.status(.badRequest).send("Bad request. Could not generate throughout.")
            next()
            return
        }
        
        switch parsedBody {
        case .json(let throughputObject):
            guard throughputObject.type == .number else {
                fallthrough
            }
            
            if let throughput = throughputObject.object as? Int {
                self.throughputGenerator.generateThroughputWithWhile(config: self.config, requestsPerSecond: throughput)
                let _ = response.send(status: .OK)
            } else if let NSThroughput = throughputObject.object as? NSNumber {
                let throughput = Int(NSThroughput)
                self.throughputGenerator.generateThroughputWithWhile(config: self.config, requestsPerSecond: throughput)
                let _ = response.send(status: .OK)
            } else {
                fallthrough
            }
        default:
            Log.error("Bad value received. Could not change delay time.")
            response.status(.badRequest).send("Bad request. Could not change delay time.")
        }
        next()
    }
    
    public func changeEndpointHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) {
        guard let parsedBody = request.body else {
            Log.error("Bad request. Could not change endpoint.")
            response.status(.badRequest).send("Bad request. Could not change endpoint.")
            next()
            return
        }
        
        switch parsedBody {
        case .json(let endpointObject):
            guard endpointObject.type == .dictionary else {
                fallthrough
            }
            
            if let endpoint = endpointObject.object as? [String: Any], let formattedEndpoint = try? formatEndpoint(URL: endpoint) {
                self.jsonEndpointHostURL = formattedEndpoint
                let _ = response.status(.OK).send("\(self.jsonEndpointHostURL)")
            } else {
                fallthrough
            }
        default:
            Log.error("Bad value received. Could not change endpoint.")
            response.status(.badRequest).send("Bad value received. Could not change endpoint.")
        }
        next()
    }
    
    func formatEndpoint(URL endpoint: [String: Any]) throws -> String {
        guard let hostURL = endpoint["host"] as? String, hostURL.characters.count > 8 else {
            throw DemoError.BadHostURL
        }
        
        // Remove trailing slashes.
        var urlCopy = hostURL
        var lastIndex = urlCopy.index(urlCopy.startIndex, offsetBy: urlCopy.characters.count-1)
        while urlCopy.characters.count > 1 && urlCopy[lastIndex] == "/" {
            urlCopy = urlCopy.substring(to: lastIndex)
            lastIndex = urlCopy.index(urlCopy.startIndex, offsetBy: urlCopy.characters.count-1)
        }
        
        // Ensure length again so our http check doesn't fail.
        guard urlCopy.characters.count > 8 else {
            throw DemoError.BadHostURL
        }
        
        // Ensure that the URL starts with http:// or https://
        let httpString = urlCopy.substring(to: urlCopy.index(urlCopy.startIndex, offsetBy: 7))
        let httpsString = urlCopy.substring(to: urlCopy.index(urlCopy.startIndex, offsetBy: 8))
        if httpString != "http://" && httpsString != "https://" {
            urlCopy = "http://\(urlCopy)"
        }
        
        // Possibly add the port.
        if let port = endpoint["port"] as? Int {
            urlCopy = "\(urlCopy):\(port)"
        } else if let port = endpoint["port"] as? NSNumber {
            urlCopy = "\(urlCopy):\(port)"
        }
        
        return urlCopy
    }

    public func changeCircuitHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) {
        guard let state = request.parameters["state"] else {
            response.status(.badRequest).send("Invalid request parameter.")
            next()
            return
        }

        guard let starterURL = URL(string: "\(self.jsonEndpointHostURL)/jsonEndpointManager") else {
            response.status(.badRequest).send("Invalid URL supplied.")
            next()
            return
        }

        var payloadDict: [String: Any] = ["delay": 0]

        switch state {
        case "open":
            payloadDict["enabled"] = false
            break
        case "close":
            payloadDict["enabled"] = true
            break
        default:
            response.status(.badRequest).send("Invalid request parameter.")
            next()
            return
        }

        guard let payloadData = try? JSONSerialization.data(withJSONObject: payloadDict, options: []) else {
            response.status(.internalServerError).send("Could not assemble request object.")
            next()
            return
        }

        networkRequest(url: starterURL, method: "POST", payload: payloadData) {
            data, urlresponse, error in
            if error != nil {
                response.status(.internalServerError).send("Error changing endpoint settings.")
            } else {
                let _ = response.send(status: .OK)
            }
            next()
        }
    }

    public func invokeCircuitHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) {
        guard let starterURL = URL(string: "\(self.jsonEndpointHostURL)/json") else {
            response.status(.badRequest).send("Invalid URL supplied.")
            next()
            return
        }

        breaker.run(args: (url: starterURL, response: response, next: next))
    }
}
