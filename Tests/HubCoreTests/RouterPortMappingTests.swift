import Foundation
@testable import HubCore
import HubLink
import XCTest

/// The router protocols' wire formats, from replies shaped like a real MiniUPnPd router's.
final class RouterPortMappingTests: XCTestCase {
    func testNATPMPAsksForTheOutsideAddressAndReadsIt() throws {
        XCTAssertEqual(NATPMP.externalAddressRequest, Data([0, 0]))
        let reply = Data([0, 128, 0, 0, 0, 1, 129, 65, 203, 0, 113, 9])
        XCTAssertEqual(try NATPMP.externalAddress(from: reply), "203.0.113.9")
    }

    func testNATPMPMapsAUDPPortAndReadsTheGrant() throws {
        XCTAssertEqual(NATPMP.mapRequest(internalPort: 38_415, externalPort: 38_415, lifetime: 3600),
                       Data([0, 1, 0, 0, 0x96, 0x0F, 0x96, 0x0F, 0, 0, 0x0E, 0x10]))
        let reply = Data([0, 129, 0, 0, 0, 1, 129, 65, 0x96, 0x0F, 0x96, 0x10, 0, 0, 0x07, 0x08])
        let grant = try NATPMP.mapping(from: reply)
        XCTAssertEqual(grant.externalPort, 38_416)
        XCTAssertEqual(grant.lifetime, 1800)
    }

    func testNATPMPRefusalsAreErrors() {
        XCTAssertThrowsError(try NATPMP.mapping(from: Data([0, 129, 0, 2, 0, 1, 129, 65, 0x96, 0x0F, 0, 0, 0, 0, 0, 0])))
        XCTAssertThrowsError(try NATPMP.externalAddress(from: Data([0, 128, 0, 0])))
    }

    func testOnlyPublicOutsideAddressesCanBeReachedFromOutside() {
        XCTAssertTrue(RouterMapping.isPublic("203.0.113.9"))
        XCTAssertTrue(RouterMapping.isPublic("88.1.2.3"))
        // A second router in front of this one, or a provider sharing one address (CGNAT).
        for address in ["10.0.0.1", "172.16.4.1", "172.31.255.1", "192.168.0.1", "100.64.0.1", "100.127.1.1", "0.0.0.0", "junk"] {
            XCTAssertFalse(RouterMapping.isPublic(address), address)
        }
        XCTAssertTrue(RouterMapping.isPublic("172.32.0.1"))
        XCTAssertTrue(RouterMapping.isPublic("100.128.0.1"))
    }

    func testSSDPRepliesPointAtTheDescription() {
        let reply = """
            HTTP/1.1 200 OK\r
            CACHE-CONTROL: max-age=120\r
            ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r
            SERVER: Netgear_Router UPnP/1.1 MiniUPnPd/2.2.0-RC0\r
            Location: http://192.168.1.1:56688/rootDesc.xml\r
            \r

            """
        XCTAssertEqual(UPnP.location(inSearchReply: reply), URL(string: "http://192.168.1.1:56688/rootDesc.xml"))
        XCTAssertNil(UPnP.location(inSearchReply: "HTTP/1.1 200 OK\r\n\r\n"))
        XCTAssertTrue(String(decoding: UPnP.searchRequest, as: UTF8.self).contains("ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n"))
    }

    func testTheDescriptionNamesTheWANConnectionService() {
        let description = Data("""
            <?xml version="1.0"?>
            <root xmlns="urn:schemas-upnp-org:device-1-0"><URLBase>http://192.168.1.1:56688</URLBase>
            <device><deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
            <serviceList><service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>
            <controlURL>/ctl/L3F</controlURL></service></serviceList>
            <deviceList><device><deviceType>urn:schemas-upnp-org:device:WANDevice:1</deviceType>
            <serviceList><service><serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType>
            <controlURL>/ctl/CmnIfCfg</controlURL></service></serviceList>
            <deviceList><device><deviceType>urn:schemas-upnp-org:device:WANConnectionDevice:1</deviceType>
            <serviceList><service><serviceType>urn:schemas-upnp-org:service:WANEthernetLinkConfig:1</serviceType>
            <controlURL>/ctl/WanEth</controlURL></service>
            <service><serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType>
            <controlURL>/ctl/PPPConn</controlURL></service></serviceList></device></deviceList></device></deviceList></device></root>
            """.utf8)
        let services = UPnP.connectionServices(inDescription: description, at: URL(string: "http://192.168.1.1:56688/rootDesc.xml")!)
        XCTAssertEqual(services.map(\.type), ["urn:schemas-upnp-org:service:WANPPPConnection:1"])
        XCTAssertEqual(services.first?.control, URL(string: "http://192.168.1.1:56688/ctl/PPPConn"))
    }

    func testControlURLsWithoutABaseAreRelativeToTheDescription() {
        let description = Data("""
            <root><device><serviceList><service>
            <serviceType>urn:schemas-upnp-org:service:WANIPConnection:2</serviceType>
            <controlURL>/upnp/control/WANIPConn1</controlURL></service></serviceList></device></root>
            """.utf8)
        let services = UPnP.connectionServices(inDescription: description, at: URL(string: "http://10.0.0.1:5000/desc.xml")!)
        XCTAssertEqual(services.first?.control, URL(string: "http://10.0.0.1:5000/upnp/control/WANIPConn1"))
    }

    func testSOAPRequestsAndReplies() {
        let body = String(decoding: UPnP.envelope(action: "AddPortMapping", service: "urn:schemas-upnp-org:service:WANIPConnection:1",
                                                  arguments: [("NewExternalPort", "38415"), ("NewProtocol", "UDP")]), as: UTF8.self)
        XCTAssertTrue(body.contains("<u:AddPortMapping xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:1\"><NewExternalPort>38415</NewExternalPort><NewProtocol>UDP</NewProtocol></u:AddPortMapping>"))

        let reply = Data("""
            <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
            <u:GetExternalIPAddressResponse xmlns:u="urn:schemas-upnp-org:service:WANPPPConnection:1">
            <NewExternalIPAddress>203.0.113.9</NewExternalIPAddress></u:GetExternalIPAddressResponse></s:Body></s:Envelope>
            """.utf8)
        XCTAssertEqual(UPnP.value("NewExternalIPAddress", in: reply), "203.0.113.9")
        XCTAssertNil(UPnP.faultCode(in: reply))

        let fault = Data("""
            <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault>
            <faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>
            <UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>725</errorCode>
            <errorDescription>OnlyPermanentLeasesSupported</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>
            """.utf8)
        XCTAssertEqual(UPnP.faultCode(in: fault), 725)
    }
}
